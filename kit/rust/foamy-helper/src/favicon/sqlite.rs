// foamy-kit 0.5.0 d0de5bb002a6af039c90d728bde78e3fb11174388482588561abc0495cd6b81b — do not edit; change foamy-kit and run sync
//! A minimal read-only SQLite reader: exactly what the favicon lookup needs
//! and nothing more. It reads the file format (rollback databases and
//! committed WAL frames, UTF-8 only), walks table b-trees, decodes records
//! with overflow pages, and takes SQLite's own `SHARED` lock on a live file
//! (open file description locks on SQLite's lock bytes, which conflict with
//! SQLite's POSIX locks), so a browser that holds its database exclusively
//! is seen as busy, exactly as SQLite sees it.
//!
//! Every structure is bounds-checked: a page type, cell pointer, varint,
//! payload size or overflow chain that doesn't fit is [`Fault::Broken`],
//! a page visited twice in one tree is a cycle (broken), and every page read
//! checks the deadline. Nothing is ever written: no journal, WAL or `-shm`
//! file is created, unlike SQLite's own read-only mode.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use rustix::fs::{self as rfs, FileType, Mode, OFlags};
use rustix::io::Errno;

/// Why a database could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Fault {
    /// Another process holds a conflicting lock (SQLite's `SQLITE_BUSY`).
    Busy,
    /// Anything else: not a database, corrupt, a hot journal, an I/O error,
    /// the deadline. The text is for tests and diagnostics only.
    Broken(String),
}

pub(crate) type Result<T> = std::result::Result<T, Fault>;

pub(crate) fn broken<T>(why: impl Into<String>) -> Result<T> {
    Err(Fault::Broken(why.into()))
}

impl From<io::Error> for Fault {
    fn from(error: io::Error) -> Self {
        Fault::Broken(error.to_string())
    }
}

impl From<Errno> for Fault {
    fn from(error: Errno) -> Self {
        Fault::Broken(io::Error::from(error).to_string())
    }
}

const MAGIC: &[u8; 16] = b"SQLite format 3\0";
const WAL_MAGIC_LE: u32 = 0x377f_0682;
const WAL_MAGIC_BE: u32 = 0x377f_0683;
const WAL_VERSION: u32 = 3_007_000;
// SQLite's lock bytes (os_unix.c): PENDING, RESERVED, then the SHARED range.
const PENDING_BYTE: i64 = 0x4000_0000;
const RESERVED_BYTE: i64 = PENDING_BYTE + 1;
const SHARED_FIRST: i64 = PENDING_BYTE + 2;
const SHARED_SIZE: i64 = 510;
/// SQLite's busy timeout in the Python helper (`timeout=0.1`).
const BUSY_TIMEOUT: Duration = Duration::from_millis(100);

/// One SQL value, as SQLite stores it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Value {
    Null,
    Int(i64),
    Real(f64),
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

impl Value {
    /// The number for `BETWEEN`, `abs()` and `-`, or `None` for NULL, text
    /// and blobs (which never fall between two numbers in SQLite).
    pub(crate) fn number(&self) -> Option<f64> {
        match *self {
            Value::Int(n) => Some(n as f64),
            Value::Real(x) if !x.is_nan() => Some(x),
            _ => None,
        }
    }

    /// SQLite's ordering across storage classes: NULL < numbers < text <
    /// blobs; numbers by value, text (BINARY collation) and blobs by bytes.
    pub(crate) fn sql_cmp(&self, other: &Value) -> Ordering {
        fn class(value: &Value) -> u8 {
            match value {
                Value::Null => 0,
                Value::Int(_) | Value::Real(_) => 1,
                Value::Text(_) => 2,
                Value::Blob(_) => 3,
            }
        }
        match (self, other) {
            (Value::Int(a), Value::Int(b)) => a.cmp(b),
            (Value::Text(a), Value::Text(b)) | (Value::Blob(a), Value::Blob(b)) => a.cmp(b),
            (a, b) if class(a) == 1 && class(b) == 1 => {
                let (x, y) = (
                    a.number().unwrap_or(f64::NAN),
                    b.number().unwrap_or(f64::NAN),
                );
                x.partial_cmp(&y).unwrap_or(Ordering::Equal)
            }
            (a, b) => class(a).cmp(&class(b)),
        }
    }

    /// A key for `=` between two INTEGER-affinity columns (no conversion
    /// between storage classes; 1 = 1.0). `None` for NULL, which equals
    /// nothing.
    pub(crate) fn join_key(&self) -> Option<Key> {
        match self {
            Value::Null => None,
            Value::Int(n) => Some(Key::Int(*n)),
            Value::Real(x) => {
                if x.fract() == 0.0 && *x >= -9.2e18 && *x <= 9.2e18 {
                    Some(Key::Int(*x as i64))
                } else if x.is_nan() {
                    None
                } else {
                    Some(Key::Real(x.to_bits()))
                }
            }
            Value::Text(bytes) => Some(Key::Text(bytes.clone())),
            Value::Blob(bytes) => Some(Key::Blob(bytes.clone())),
        }
    }
}

/// See [`Value::join_key`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Key {
    Int(i64),
    Real(u64),
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

/// `(dev, ino, size, mtime_ns, ctime_ns)`, as the Python helper compares.
pub(crate) type FileState = (u64, u64, u64, i128, i128);

pub(crate) fn state_of(meta: &std::fs::Metadata) -> FileState {
    (
        meta.dev(),
        meta.ino(),
        meta.size(),
        meta.mtime() as i128 * 1_000_000_000 + meta.mtime_nsec() as i128,
        meta.ctime() as i128 * 1_000_000_000 + meta.ctime_nsec() as i128,
    )
}

fn open_nofollow(path: &Path) -> io::Result<File> {
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
    Ok(File::from(rfs::open(path, flags, Mode::empty())?))
}

/// `path` with `suffix` appended to its last component (`-journal`, `-wal`).
pub(crate) fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

enum Source {
    Memory(Vec<u8>),
    File(File),
}

struct Wal {
    file: File,
    /// Page number → file offset of the newest committed frame's page data.
    frames: HashMap<u32, u64>,
    /// Database size in pages after the last commit.
    pages: u32,
}

/// A read-only view of one database: an in-memory image (the Python
/// helper's `deserialize`d snapshot) or a live file under a `SHARED` lock,
/// with the committed frames of its WAL laid over it.
pub(crate) struct Database {
    source: Source,
    wal: Option<Wal>,
    page_size: usize,
    usable: usize,
    page_count: u32,
    deadline: Instant,
    /// For live files: the database and WAL state when opened.
    states: Vec<(PathBuf, Option<FileState>)>,
}

/// The parts of the 100-byte header the reader needs.
struct Header {
    page_size: usize,
    usable: usize,
    pages: u32,
}

/// The page size from a database header (checks the magic first).
fn page_size_of(page1: &[u8]) -> Result<usize> {
    if page1.len() < 100 || &page1[..16] != MAGIC {
        return broken("file is not a database");
    }
    let raw = u16::from_be_bytes([page1[16], page1[17]]) as usize;
    let page_size = if raw == 1 { 65536 } else { raw };
    if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
        return broken("invalid page size");
    }
    Ok(page_size)
}

/// The header of a database whose file (or WAL) holds `file_pages` pages.
fn header(page1: &[u8], file_pages: u64) -> Result<Header> {
    let page_size = page_size_of(page1)?;
    if page1[19] > 2 {
        return broken("unsupported file format version");
    }
    if page1[21..24] != [64, 32, 32] {
        return broken("invalid payload fractions");
    }
    let usable = page_size - page1[20] as usize;
    if usable < 480 {
        return broken("invalid reserved space");
    }
    if be32(&page1[56..60]) > 1 {
        return broken("only UTF-8 databases are supported");
    }
    let in_header = be32(&page1[28..32]);
    let pages = if in_header != 0 && page1[24..28] == page1[92..96] {
        in_header as u64
    } else {
        file_pages
    };
    if pages > file_pages {
        return broken("database is shorter than its header says");
    }
    Ok(Header {
        page_size,
        usable,
        pages: u32::try_from(pages).or_else(|_| broken("database too large"))?,
    })
}

fn be16(bytes: &[u8]) -> usize {
    u16::from_be_bytes([bytes[0], bytes[1]]) as usize
}

fn be32(bytes: &[u8]) -> u32 {
    u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// A SQLite varint at `at`: (value, length).
fn varint(bytes: &[u8], at: usize) -> Result<(u64, usize)> {
    let mut value = 0u64;
    for i in 0..9 {
        let Some(&byte) = bytes.get(at + i) else {
            return broken("truncated varint");
        };
        if i == 8 {
            return Ok(((value << 8) | byte as u64, 9));
        }
        value = (value << 7) | (byte & 0x7f) as u64;
        if byte & 0x80 == 0 {
            return Ok((value, i + 1));
        }
    }
    unreachable!("a varint has at most nine bytes")
}

/// `fcntl(F_OFD_SETLK)` (`kind` `F_RDLCK`, `F_WRLCK` or `F_UNLCK`): false
/// when another process holds a conflicting lock.
fn ofd_lock(file: &File, kind: i32, start: i64, len: i64) -> io::Result<bool> {
    let lock = libc::flock {
        l_type: kind as libc::c_short,
        l_whence: libc::SEEK_SET as libc::c_short,
        l_start: start,
        l_len: len,
        l_pid: 0,
    };
    // SAFETY: `lock` is a valid, initialised `struct flock` that outlives
    // the call, and the fd is open for the lifetime of `file`.
    let rc = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_OFD_SETLK, &lock) };
    if rc == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::EAGAIN) | Some(libc::EACCES) => Ok(false),
        _ => Err(error),
    }
}

/// Whether another process holds SQLite's `RESERVED` lock (a writer).
fn reserved_by_other(file: &File) -> io::Result<bool> {
    let mut lock = libc::flock {
        l_type: libc::F_WRLCK as libc::c_short,
        l_whence: libc::SEEK_SET as libc::c_short,
        l_start: RESERVED_BYTE,
        l_len: 1,
        l_pid: 0,
    };
    // SAFETY: as in `ofd_lock`; F_OFD_GETLK writes into `lock`, which is a
    // valid mutable `struct flock`.
    let rc = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_OFD_GETLK, &mut lock) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(lock.l_type != libc::F_UNLCK as libc::c_short)
}

/// SQLite's `SHARED` lock (os_unix.c `unixLock`): a read lock on the
/// PENDING byte, a read lock on the SHARED range, the PENDING byte released.
/// Retried for [`BUSY_TIMEOUT`] like SQLite's busy handler.
fn lock_shared(file: &File, deadline: Instant) -> Result<()> {
    let until = (Instant::now() + BUSY_TIMEOUT).min(deadline);
    loop {
        if ofd_lock(file, libc::F_RDLCK, PENDING_BYTE, 1)? {
            let shared = ofd_lock(file, libc::F_RDLCK, SHARED_FIRST, SHARED_SIZE)?;
            ofd_lock(file, libc::F_UNLCK, PENDING_BYTE, 1)?;
            if shared {
                return Ok(());
            }
        }
        if Instant::now() >= until {
            return Err(Fault::Busy);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// A rollback journal SQLite would have to replay (pager.c
/// `hasHotJournal`): it exists, no writer holds RESERVED, the database has
/// pages, and its first byte is not zero. A read-only SQLite connection
/// fails on it (`SQLITE_READONLY_ROLLBACK`), so this does too.
fn hot_journal(db: &File, path: &Path, db_size: u64) -> Result<bool> {
    let journal = sidecar(path, "-journal");
    if std::fs::metadata(&journal).is_err() {
        return Ok(false);
    }
    if reserved_by_other(db)? || db_size == 0 {
        return Ok(false);
    }
    let file = open_nofollow(&journal)?;
    let mut first = [0u8; 1];
    let read = file.read_at(&mut first, 0)?;
    Ok(read == 1 && first[0] != 0)
}

/// WAL checksum (wal.c `walChecksumBytes`), continuing from `sum`.
fn wal_checksum(big_endian: bool, data: &[u8], sum: (u32, u32)) -> (u32, u32) {
    let (mut s1, mut s2) = sum;
    let word = |raw: [u8; 4]| {
        if big_endian {
            u32::from_be_bytes(raw)
        } else {
            u32::from_le_bytes(raw)
        }
    };
    for pair in data.as_chunks::<8>().0 {
        let (first, second) = pair.split_at(4);
        s1 = s1
            .wrapping_add(word(first.try_into().expect("four bytes")))
            .wrapping_add(s2);
        s2 = s2
            .wrapping_add(word(second.try_into().expect("four bytes")))
            .wrapping_add(s1);
    }
    (s1, s2)
}

/// Reads a WAL the way SQLite recovers its index: frames are valid while
/// their salts match the header and the running checksum holds; only
/// frames up to the last commit frame count. An invalid header means no
/// frames (SQLite ignores such a WAL).
fn read_wal(file: File, page_size: usize, deadline: Instant) -> Result<Wal> {
    let size = file.metadata()?.len();
    let mut wal = Wal {
        file,
        frames: HashMap::new(),
        pages: 0,
    };
    let mut head = [0u8; 32];
    if size < 32 || wal.file.read_at(&mut head, 0)? != 32 {
        return Ok(wal);
    }
    let magic = be32(&head[0..4]);
    if (magic != WAL_MAGIC_LE && magic != WAL_MAGIC_BE)
        || be32(&head[4..8]) != WAL_VERSION
        || be32(&head[8..12]) as usize != page_size
    {
        return Ok(wal);
    }
    let big_endian = magic & 1 == 1;
    let mut sum = wal_checksum(big_endian, &head[..24], (0, 0));
    if sum != (be32(&head[24..28]), be32(&head[28..32])) {
        return Ok(wal);
    }
    let salt = &head[16..24];
    let frame_size = 24 + page_size as u64;
    let mut frame = vec![0u8; frame_size as usize];
    let mut pending = Vec::new();
    let mut offset = 32u64;
    while offset + frame_size <= size {
        if Instant::now() >= deadline {
            return broken("lookup deadline exceeded");
        }
        if wal.file.read_at(&mut frame, offset)? != frame.len() {
            break;
        }
        let page = be32(&frame[0..4]);
        if page == 0 || &frame[8..16] != salt {
            break;
        }
        sum = wal_checksum(big_endian, &frame[..8], sum);
        sum = wal_checksum(big_endian, &frame[24..], sum);
        if sum != (be32(&frame[16..20]), be32(&frame[20..24])) {
            break;
        }
        pending.push((page, offset + 24));
        let commit = be32(&frame[4..8]);
        if commit != 0 {
            wal.frames.extend(pending.drain(..));
            wal.pages = commit;
        }
        offset += frame_size;
    }
    Ok(wal)
}

/// A cell's payload: the bytes on its page, and where the rest continues.
struct Payload {
    local: Vec<u8>,
    total: u64,
    overflow: u32,
}

/// One decoded record: the payload plus the column layout from its header.
pub(crate) struct Record<'a> {
    db: &'a Database,
    payload: Payload,
    /// (serial type, offset in the payload) per stored column.
    columns: Vec<(u64, u64)>,
    pub(crate) rowid: i64,
}

fn serial_len(kind: u64) -> Result<u64> {
    Ok(match kind {
        0 | 8 | 9 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 | 7 => 8,
        10 | 11 => return broken("reserved serial type"),
        n => (n - 12) / 2,
    })
}

impl Record<'_> {
    /// Number of columns stored in this record (older rows may have fewer
    /// than the table, after `ALTER TABLE ADD COLUMN`).
    pub(crate) fn len(&self) -> usize {
        self.columns.len()
    }

    /// Storage class and byte length of column `index`, without reading it:
    /// `(is_text, is_blob, length)`; `None` when the column isn't stored.
    pub(crate) fn kind(&self, index: usize) -> Option<(bool, bool, u64)> {
        let &(kind, _) = self.columns.get(index)?;
        let length = serial_len(kind).ok()?;
        Some((
            kind >= 13 && kind % 2 == 1,
            kind >= 12 && kind % 2 == 0,
            length,
        ))
    }

    /// Column `index`; for text and blobs at most `limit` bytes of it.
    pub(crate) fn value(&self, index: usize, limit: usize) -> Result<Value> {
        let Some(&(kind, offset)) = self.columns.get(index) else {
            return Ok(Value::Null);
        };
        let length = serial_len(kind)?;
        let wanted = if kind >= 12 {
            length.min(limit as u64)
        } else {
            length
        };
        let bytes = self.bytes(offset, wanted)?;
        let int = |bytes: &[u8]| {
            let mut value = if bytes[0] & 0x80 != 0 { -1i64 } else { 0 };
            for &byte in bytes {
                value = (value << 8) | byte as i64;
            }
            value
        };
        Ok(match kind {
            0 => Value::Null,
            1..=6 => Value::Int(int(&bytes)),
            7 => Value::Real(f64::from_bits(u64::from_be_bytes(
                bytes[..8].try_into().expect("eight bytes"),
            ))),
            8 => Value::Int(0),
            9 => Value::Int(1),
            n if n % 2 == 0 => Value::Blob(bytes),
            _ => Value::Text(bytes),
        })
    }

    /// `length` bytes of the payload from `offset`, following the overflow
    /// chain only as far as needed.
    fn bytes(&self, offset: u64, length: u64) -> Result<Vec<u8>> {
        let end = offset
            .checked_add(length)
            .filter(|&end| end <= self.payload.total)
            .map_or_else(|| broken("column beyond its payload"), Ok)?;
        let local = self.payload.local.len() as u64;
        let mut out = Vec::with_capacity(length as usize);
        if offset < local {
            out.extend_from_slice(&self.payload.local[offset as usize..end.min(local) as usize]);
        }
        if end <= local {
            return Ok(out);
        }
        let chunk = (self.db.usable - 4) as u64;
        let mut page = self.payload.overflow;
        let mut start = local;
        let mut seen = HashSet::new();
        while start < end {
            if page == 0 || !seen.insert(page) {
                return broken("overflow chain is too short or loops");
            }
            let data = self.db.page(page)?;
            let here = (end - start).min(chunk);
            if offset < start + here {
                let from = offset.saturating_sub(start);
                out.extend_from_slice(&data[4 + from as usize..4 + here as usize]);
            }
            start += here;
            page = be32(&data[0..4]);
        }
        Ok(out)
    }
}

impl Database {
    /// The in-memory image of a database file (a snapshot).
    pub(crate) fn from_image(image: Vec<u8>, deadline: Instant) -> Result<Database> {
        let page_size = page_size_of(&image)?;
        let header = header(&image, image.len() as u64 / page_size as u64)?;
        Ok(Database {
            source: Source::Memory(image),
            wal: None,
            page_size: header.page_size,
            usable: header.usable,
            page_count: header.pages,
            deadline,
            states: Vec::new(),
        })
    }

    /// Opens a live database like a read-only SQLite connection: `SHARED`
    /// lock (busy → [`Fault::Busy`]), hot-journal check, then the WAL's
    /// committed frames if a `-wal` file exists. The lock is held until the
    /// `Database` is dropped. Symlinks are never followed.
    pub(crate) fn open_live(path: &Path, deadline: Instant) -> Result<Database> {
        let file = open_nofollow(path)?;
        if FileType::from_raw_mode(file.metadata()?.mode()) != FileType::RegularFile {
            return broken("not a regular file");
        }
        lock_shared(&file, deadline)?;
        let meta = file.metadata()?;
        if hot_journal(&file, path, meta.len())? {
            return broken("hot journal (a read-only connection cannot roll it back)");
        }
        let mut page1 = vec![0u8; 100];
        let read = file.read_at(&mut page1, 0)?;
        page1.truncate(read);
        if read == 0 {
            return broken("empty database (no such table)");
        }
        let page_size = page_size_of(&page1)?;
        let mut states = vec![(path.to_path_buf(), Some(state_of(&meta)))];
        let wal_path = sidecar(path, "-wal");
        let wal = match std::fs::symlink_metadata(&wal_path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                states.push((wal_path, None));
                None
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {
                let wal_file = open_nofollow(&wal_path)?;
                let wal_meta = wal_file.metadata()?;
                if FileType::from_raw_mode(wal_meta.mode()) != FileType::RegularFile {
                    return broken("WAL is not a regular file");
                }
                states.push((wal_path, Some(state_of(&wal_meta))));
                Some(read_wal(wal_file, page_size, deadline)?)
            }
        };
        let file_pages = meta.len() / page_size as u64;
        let mut db = Database {
            source: Source::File(file),
            wal,
            page_size,
            usable: 0,
            page_count: u32::MAX,
            deadline,
            states,
        };
        // Page 1 may itself be in the WAL.
        let page1 = db.page(1)?;
        let committed = db.wal.as_ref().map_or(0, |wal| wal.pages);
        let header = if committed != 0 {
            header(&page1, committed as u64)?
        } else {
            header(&page1, file_pages)?
        };
        if header.page_size != page_size {
            return broken("page size changed");
        }
        db.usable = header.usable;
        db.page_count = if committed != 0 {
            committed
        } else {
            header.pages
        };
        Ok(db)
    }

    /// For a live database: whether the database and WAL files are as they
    /// were when opened (a WAL reader holds no WAL lock, so a concurrent
    /// checkpoint is detected here instead).
    pub(crate) fn unchanged(&self) -> bool {
        self.states.iter().all(|(path, state)| {
            let now = std::fs::symlink_metadata(path)
                .ok()
                .map(|meta| state_of(&meta));
            now == *state
        })
    }

    /// Page `number` (1-based), newest committed WAL frame first.
    fn page(&self, number: u32) -> Result<Vec<u8>> {
        if Instant::now() >= self.deadline {
            return broken("lookup deadline exceeded");
        }
        if number == 0 || number > self.page_count {
            return broken(format!("page {number} out of range"));
        }
        let size = self.page_size;
        let mut data = vec![0u8; size];
        if let Some(wal) = &self.wal
            && let Some(&offset) = wal.frames.get(&number)
        {
            if wal.file.read_at(&mut data, offset)? != size {
                return broken("truncated WAL frame");
            }
            return Ok(data);
        }
        let start = (number as u64 - 1) * size as u64;
        match &self.source {
            Source::Memory(image) => {
                let range = start as usize..start as usize + size;
                let bytes = image
                    .get(range)
                    .map_or_else(|| broken("truncated database"), Ok)?;
                data.copy_from_slice(bytes);
            }
            Source::File(file) => {
                let mut filled = 0;
                while filled < size {
                    match file.read_at(&mut data[filled..], start + filled as u64)? {
                        0 => return broken("truncated database"),
                        n => filled += n,
                    }
                }
            }
        }
        Ok(data)
    }

    fn local_size(&self, total: u64, table: bool) -> usize {
        let usable = self.usable as u64;
        let max = if table {
            usable - 35
        } else {
            (usable - 12) * 64 / 255 - 23
        };
        if total <= max {
            return total as usize;
        }
        let min = (usable - 12) * 32 / 255 - 23;
        let k = min + (total - min) % (usable - 4);
        (if k <= max { k } else { min }) as usize
    }

    /// Visits every row of the table b-tree at `root` in rowid order. With
    /// `check`, index b-trees are accepted too and every overflow chain is
    /// walked (the structural part of `PRAGMA quick_check`); `seen` collects
    /// the pages, so a page used twice anywhere is found.
    fn walk<'a>(
        &'a self,
        root: u32,
        check: bool,
        seen: &mut HashSet<u32>,
        visit: &mut dyn FnMut(Record<'a>) -> Result<()>,
    ) -> Result<()> {
        let mut stack = vec![root];
        let mut table = None;
        while let Some(number) = stack.pop() {
            if !seen.insert(number) {
                return broken(format!("page {number} is used twice"));
            }
            let data = self.page(number)?;
            let base = if number == 1 { 100 } else { 0 };
            let kind = data[base];
            let is_table = match kind {
                5 | 13 => true,
                2 | 10 if check => false,
                _ => return broken(format!("page {number} has invalid type {kind}")),
            };
            if *table.get_or_insert(is_table) != is_table {
                return broken("table and index pages mixed in one tree");
            }
            let interior = kind == 2 || kind == 5;
            let header_len = if interior { 12 } else { 8 };
            let cells = be16(&data[base + 3..]);
            let content = match be16(&data[base + 5..]) {
                0 => 65536,
                n => n,
            };
            let pointers = base + header_len;
            if pointers + 2 * cells > content.min(self.usable) || content > self.usable {
                return broken(format!("page {number} has too many cells"));
            }
            let mut children = Vec::new();
            for i in 0..cells {
                let at = be16(&data[pointers + 2 * i..]);
                if at < pointers + 2 * cells || at >= self.usable {
                    return broken(format!("page {number} has a bad cell pointer"));
                }
                let cell = &data[..self.usable];
                if interior {
                    if at + 4 > cell.len() {
                        return broken("truncated cell");
                    }
                    children.push(be32(&cell[at..]));
                    if !is_table {
                        self.payload(cell, at + 4, false, check)?;
                    }
                    continue;
                }
                let (total, n) = varint(cell, at)?;
                let mut at = at + n;
                let rowid = if is_table {
                    let (rowid, n) = varint(cell, at)?;
                    at += n;
                    rowid as i64
                } else {
                    0
                };
                let payload = self.payload_from(cell, at, total, is_table, check)?;
                if is_table {
                    visit(self.record(payload, rowid)?)?;
                }
            }
            if interior {
                children.push(be32(&data[base + 8..]));
            }
            // Leftmost child first: push in reverse.
            stack.extend(children.into_iter().rev());
        }
        Ok(())
    }

    fn payload(&self, cell: &[u8], at: usize, table: bool, check: bool) -> Result<Payload> {
        let (total, n) = varint(cell, at)?;
        self.payload_from(cell, at + n, total, table, check)
    }

    fn payload_from(
        &self,
        cell: &[u8],
        at: usize,
        total: u64,
        table: bool,
        check: bool,
    ) -> Result<Payload> {
        let local = self.local_size(total, table);
        let spills = (local as u64) < total;
        let end = at + local + if spills { 4 } else { 0 };
        if end > cell.len() {
            return broken("cell overflows its page");
        }
        let payload = Payload {
            local: cell[at..at + local].to_vec(),
            total,
            overflow: if spills { be32(&cell[at + local..]) } else { 0 },
        };
        if check && spills {
            let mut left = total - local as u64;
            let mut page = payload.overflow;
            let mut seen = HashSet::new();
            while left > 0 {
                if page == 0 || !seen.insert(page) {
                    return broken("overflow chain is too short or loops");
                }
                page = be32(&self.page(page)?[..4]);
                left = left.saturating_sub((self.usable - 4) as u64);
            }
            if page != 0 {
                return broken("overflow chain is too long");
            }
        }
        Ok(payload)
    }

    fn record(&self, payload: Payload, rowid: i64) -> Result<Record<'_>> {
        let (header_len, mut at) = {
            let (len, n) = varint(&payload.local, 0).or_else(|_| broken("record header"))?;
            (len, n as u64)
        };
        if header_len > payload.total || header_len as usize > payload.local.len() {
            // Headers longer than the local part only occur in records with
            // thousands of columns; the favicon tables have a handful.
            return broken("record header is not on its page");
        }
        let mut columns = Vec::new();
        let mut offset = header_len;
        while at < header_len {
            let (kind, n) = varint(&payload.local[..header_len as usize], at as usize)?;
            at += n as u64;
            columns.push((kind, offset));
            offset += serial_len(kind)?;
        }
        if offset > payload.total {
            return broken("record is longer than its payload");
        }
        Ok(Record {
            db: self,
            payload,
            columns,
            rowid,
        })
    }

    /// Visits the rows of the table at `root` in rowid order. A record
    /// keeps its payload, so a caller may hold on to a few and read their
    /// large columns later.
    pub(crate) fn scan<'a>(
        &'a self,
        root: u32,
        visit: &mut dyn FnMut(Record<'a>) -> Result<()>,
    ) -> Result<()> {
        self.walk(root, false, &mut HashSet::new(), visit)
    }

    /// The structural part of `PRAGMA quick_check`: every b-tree in the
    /// schema (tables and indexes) is walked with every overflow chain, and
    /// no page may be used twice.
    pub(crate) fn check(&self) -> Result<()> {
        let mut seen = HashSet::new();
        let mut roots = Vec::new();
        self.walk(1, true, &mut seen, &mut |record| {
            if let Value::Int(root) = record.value(3, 0)?
                && root > 0
            {
                roots.push(u32::try_from(root).or_else(|_| broken("root page out of range"))?);
            }
            Ok(())
        })?;
        for root in roots {
            self.walk(root, true, &mut seen, &mut |_| Ok(()))?;
        }
        Ok(())
    }

    /// The `CREATE TABLE` statement and root page of table `name` from
    /// `sqlite_schema` (names compare case-insensitively, like SQLite's).
    pub(crate) fn table(&self, name: &str) -> Result<Option<(u32, String)>> {
        let mut found = None;
        self.scan(1, &mut |record| {
            let text = |value: Value| match value {
                Value::Text(bytes) => String::from_utf8(bytes).ok(),
                _ => None,
            };
            let kind = text(record.value(0, 64)?);
            let table = text(record.value(1, 4096)?);
            if kind.as_deref() == Some("table")
                && table.is_some_and(|table| table.eq_ignore_ascii_case(name))
                && found.is_none()
            {
                let Value::Int(root) = record.value(3, 0)? else {
                    return broken("table has no root page");
                };
                let sql = text(record.value(4, 1 << 20)?).unwrap_or_default();
                found = Some((
                    u32::try_from(root).or_else(|_| broken("bad root page"))?,
                    sql,
                ));
            }
            Ok(())
        })?;
        Ok(found)
    }
}

/// One column of a `CREATE TABLE` statement.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Column {
    pub(crate) name: String,
    /// An `INTEGER PRIMARY KEY` column: stored as NULL, its value is the rowid.
    pub(crate) rowid: bool,
    /// Its `DEFAULT` when that is an integer literal (rows written before
    /// an `ALTER TABLE ADD COLUMN` don't store the column).
    pub(crate) default: Value,
}

fn split_top_level(body: &str) -> Vec<String> {
    let mut parts = vec![String::new()];
    let mut depth = 0usize;
    let mut quote: Option<char> = None;
    for c in body.chars() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
            }
            None => match c {
                '\'' | '"' | '`' => quote = Some(c),
                '[' => quote = Some(']'),
                '(' => depth += 1,
                ')' => depth = depth.saturating_sub(1),
                ',' if depth == 0 => {
                    parts.push(String::new());
                    continue;
                }
                _ => {}
            },
        }
        parts.last_mut().expect("never empty").push(c);
    }
    parts
}

fn tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else if matches!(c, '\'' | '"' | '`' | '[') {
            let close = if c == '[' { ']' } else { c };
            chars.next();
            let mut token = String::new();
            for c in chars.by_ref() {
                if c == close {
                    break;
                }
                token.push(c);
            }
            out.push(token);
        } else if c == '(' || c == ')' || c == ',' {
            out.push(c.to_string());
            chars.next();
        } else {
            let mut token = String::new();
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() || matches!(c, '(' | ')' | ',' | '\'' | '"' | '`' | '[') {
                    break;
                }
                token.push(c);
                chars.next();
            }
            out.push(token);
        }
    }
    out
}

const CONSTRAINTS: &[&str] = &[
    "CONSTRAINT",
    "PRIMARY",
    "NOT",
    "NULL",
    "UNIQUE",
    "CHECK",
    "DEFAULT",
    "COLLATE",
    "REFERENCES",
    "GENERATED",
    "AS",
];

/// The stored columns of a `CREATE TABLE` statement, in record order.
/// Refuses what this reader can't map to records: `WITHOUT ROWID` tables
/// and generated columns.
pub(crate) fn columns(sql: &str) -> Result<Vec<Column>> {
    let (Some(open), Some(close)) = (sql.find('('), sql.rfind(')')) else {
        return broken("no column list");
    };
    if open >= close {
        return broken("no column list");
    }
    let tail = sql[close + 1..].to_ascii_uppercase();
    if tail.contains("WITHOUT") {
        return broken("WITHOUT ROWID tables are not supported");
    }
    let mut columns: Vec<(Column, String)> = Vec::new();
    let mut table_key: Option<Vec<String>> = None;
    for part in split_top_level(&sql[open + 1..close]) {
        let words = tokens(&part);
        let Some(first) = words.first() else { continue };
        let upper: Vec<String> = words.iter().map(|w| w.to_ascii_uppercase()).collect();
        if matches!(
            upper[0].as_str(),
            "CONSTRAINT" | "PRIMARY" | "UNIQUE" | "CHECK" | "FOREIGN"
        ) {
            if let Some(at) = upper.iter().position(|w| w == "PRIMARY")
                && upper.get(at + 1).map(String::as_str) == Some("KEY")
            {
                let names: Vec<String> = words[at + 2..]
                    .iter()
                    .filter(|w| !matches!(w.as_str(), "(" | ")" | ","))
                    .take_while(|w| !w.eq_ignore_ascii_case("ON"))
                    .cloned()
                    .collect();
                table_key = Some(names);
            }
            continue;
        }
        if upper.iter().any(|w| w == "GENERATED")
            || upper.windows(2).any(|w| w[0] == "AS" && w[1] == "(")
        {
            return broken("generated columns are not supported");
        }
        let kind: Vec<&str> = upper[1..]
            .iter()
            .take_while(|w| !CONSTRAINTS.contains(&w.as_str()))
            .map(String::as_str)
            .collect();
        let primary = upper.windows(2).any(|w| w[0] == "PRIMARY" && w[1] == "KEY");
        let desc = upper.iter().any(|w| w == "DESC");
        let default = upper
            .iter()
            .position(|w| w == "DEFAULT")
            .and_then(|at| words.get(at + 1))
            .and_then(|literal| literal.parse::<i64>().ok())
            .map_or(Value::Null, Value::Int);
        columns.push((
            Column {
                name: first.clone(),
                rowid: primary && !desc && kind == ["INTEGER"],
                default,
            },
            kind.join(" "),
        ));
    }
    if let Some(names) = table_key
        && let [name] = names.as_slice()
        && let Some((column, kind)) = columns
            .iter_mut()
            .find(|(column, _)| column.name.eq_ignore_ascii_case(name))
    {
        column.rowid = kind == "INTEGER";
    }
    Ok(columns.into_iter().map(|(column, _)| column).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_decode_one_to_nine_bytes() {
        assert_eq!(varint(&[0x05], 0).unwrap(), (5, 1));
        assert_eq!(varint(&[0x81, 0x00], 0).unwrap(), (128, 2));
        assert_eq!(varint(&[0xff; 9], 0).unwrap(), (u64::MAX, 9));
        assert!(varint(&[0x81], 0).is_err());
    }

    #[test]
    fn values_order_like_sqlite() {
        let order = [
            Value::Null,
            Value::Int(-1),
            Value::Real(0.5),
            Value::Int(2),
            Value::Text(b"a".to_vec()),
            Value::Blob(vec![0]),
        ];
        for pair in order.windows(2) {
            assert_eq!(pair[0].sql_cmp(&pair[1]), Ordering::Less, "{pair:?}");
        }
        assert_eq!(Value::Real(1.0).join_key(), Value::Int(1).join_key());
        assert_eq!(Value::Null.join_key(), None);
        assert_ne!(
            Value::Text(b"1".to_vec()).join_key(),
            Value::Int(1).join_key()
        );
    }

    #[test]
    fn create_table_columns() {
        let chromium = "CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY,icon_id INTEGER NOT NULL,last_updated INTEGER DEFAULT 0,image_data BLOB,width INTEGER DEFAULT 0,height INTEGER DEFAULT 0,last_requested INTEGER NOT NULL DEFAULT 0)";
        let cols = columns(chromium).unwrap();
        let names: Vec<&str> = cols.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "id",
                "icon_id",
                "last_updated",
                "image_data",
                "width",
                "height",
                "last_requested"
            ]
        );
        assert!(cols[0].rowid && !cols[1].rowid);
        assert_eq!(cols[4].default, Value::Int(0));
        assert_eq!(cols[3].default, Value::Null);
        let quoted = columns("CREATE TABLE \"t\" ([page url] TEXT, `icon_id` INTEGER, CHECK (x > 0), PRIMARY KEY(icon_id))").unwrap();
        assert_eq!(quoted[0].name, "page url");
        assert!(
            quoted[1].rowid,
            "table-level PRIMARY KEY on one INTEGER column"
        );
        assert!(!columns("CREATE TABLE t(id INTEGER PRIMARY KEY DESC)").unwrap()[0].rowid);
        assert!(!columns("CREATE TABLE t(id INT PRIMARY KEY)").unwrap()[0].rowid);
        assert!(columns("CREATE TABLE t(a INTEGER PRIMARY KEY) WITHOUT ROWID").is_err());
        assert!(columns("CREATE TABLE t(a, b AS (a + 1))").is_err());
        assert!(columns("CREATE TABLE t").is_err());
    }

    #[test]
    fn header_checks() {
        let mut page = vec![0u8; 512];
        page[..16].copy_from_slice(MAGIC);
        page[16..18].copy_from_slice(&512u16.to_be_bytes());
        page[18] = 1;
        page[19] = 1;
        page[21..24].copy_from_slice(&[64, 32, 32]);
        page[56..60].copy_from_slice(&1u32.to_be_bytes());
        assert_eq!(header(&page, 1).unwrap().pages, 1);
        let mut utf16 = page.clone();
        utf16[56..60].copy_from_slice(&2u32.to_be_bytes());
        assert!(header(&utf16, 1).is_err());
        let mut odd = page.clone();
        odd[16..18].copy_from_slice(&1000u16.to_be_bytes());
        assert!(header(&odd, 1).is_err());
        let mut long = page.clone();
        long[24..28].copy_from_slice(&[0, 0, 0, 7]);
        long[92..96].copy_from_slice(&[0, 0, 0, 7]);
        long[28..32].copy_from_slice(&[0, 0, 0, 9]);
        assert!(
            header(&long, 1).is_err(),
            "header claims more pages than the file has"
        );
        assert!(header(b"not a database", 1).is_err());
    }

    #[test]
    fn wal_checksum_matches_sqlite() {
        // Eight zero bytes: s1 = 0, s2 = 0; then the words feed forward.
        assert_eq!(wal_checksum(true, &[0; 8], (0, 0)), (0, 0));
        assert_eq!(
            wal_checksum(true, &[0, 0, 0, 1, 0, 0, 0, 2], (0, 0)),
            (1, 3)
        );
        assert_eq!(
            wal_checksum(false, &[1, 0, 0, 0, 2, 0, 0, 0], (0, 0)),
            (1, 3)
        );
    }
}
