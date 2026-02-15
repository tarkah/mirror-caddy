use clap::Parser;
use serde::Deserialize;
use std::path::{Path, PathBuf};

use tokio::fs;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::Semaphore;

// ── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(about = "Mirror files from a Caddy file server with browse enabled.")]
#[command(after_help = "Environment:\n  PARALLEL_JOBS  Max concurrent downloads (default: 50)")]
struct Args {
    /// URL of the Caddy file server
    #[arg(value_name = "base-url")]
    base_url: String,

    /// Local directory to save files (default: .)
    #[arg(value_name = "download-dir", default_value = ".")]
    download_dir: String,

    /// Debug output (-vv for trace)
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

// ── Colors ──────────────────────────────────────────────────────────────────

const GREEN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const MAGENTA: &str = "\x1b[0;35m";
const CYAN: &str = "\x1b[0;96m";
const NC: &str = "\x1b[0m";

// ── Logging ─────────────────────────────────────────────────────────────────

struct Logger {
    verbose: u8,
    spinner_active: std::sync::atomic::AtomicBool,
}

impl Logger {
    fn new(verbose: u8) -> Self {
        Self {
            verbose,
            spinner_active: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn emit(&self, msg: &str) {
        if self.spinner_active.load(Ordering::Relaxed) {
            eprint!("\r\x1b[K");
        }
        eprintln!("{msg}");
    }

    fn info(&self, msg: &str) {
        self.emit(&format!("{GREEN}[INFO]{NC} {msg}"));
    }

    fn error(&self, msg: &str) {
        self.emit(&format!("{RED}[ERROR]{NC} {msg}"));
    }

    fn debug(&self, msg: &str) {
        if self.verbose >= 1 {
            self.emit(&format!("{MAGENTA}[DEBUG]{NC} {msg}"));
        }
    }

    fn trace(&self, msg: &str) {
        if self.verbose >= 2 {
            self.emit(&format!("{CYAN}[TRACE]{NC} {msg}"));
        }
    }
}

// ── Caddy directory entry ───────────────────────────────────────────────────

#[derive(Deserialize)]
struct CaddyEntry {
    name: Option<String>,
    url: Option<String>,
    #[serde(default)]
    is_dir: bool,
}

// ── Metadata ────────────────────────────────────────────────────────────────

async fn read_metadata(path: &Path) -> (Option<String>, Option<String>) {
    let Ok(content) = fs::read_to_string(path).await else {
        return (None, None);
    };
    let mut etag = None;
    let mut last_modified = None;
    for line in content.lines() {
        if let Some(v) = line.strip_prefix("etag=") {
            if !v.is_empty() && v != "null" {
                etag = Some(v.to_string());
            }
        } else if let Some(v) = line.strip_prefix("last_modified=") {
            if !v.is_empty() && v != "null" {
                last_modified = Some(v.to_string());
            }
        }
    }
    (etag, last_modified)
}

async fn save_metadata(path: &Path, etag: &str, last_modified: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent).await;
    }
    let _ = fs::write(path, format!("etag={etag}\nlast_modified={last_modified}\n")).await;
}

// ── Enumeration ─────────────────────────────────────────────────────────────

/// Channel-based work queue enumeration: N workers pull directory URLs from a
/// shared queue, list them, push subdirs back, and collect files. No task ever
/// holds a "permit" while waiting on another task, so deadlock is impossible.
async fn enumerate_files(
    client: &reqwest::Client,
    base_url: &str,
    log: &Arc<Logger>,
    counter: &Arc<AtomicUsize>,
    max_concurrent: usize,
) -> Vec<(String, String)> {
    // (dir_url, path_prefix)
    let (tx, rx) = async_channel::unbounded::<(String, String)>();
    let in_flight = Arc::new(AtomicUsize::new(1)); // 1 for the seed item

    // Seed the queue with the root directory
    tx.send((format!("{base_url}/"), String::new())).await.unwrap();

    let mut workers = Vec::with_capacity(max_concurrent);
    for _ in 0..max_concurrent {
        let rx = rx.clone();
        let tx = tx.clone();
        let client = client.clone();
        let in_flight = in_flight.clone();
        let log = log.clone();
        let counter = counter.clone();

        workers.push(tokio::spawn(async move {
            let mut local_files = Vec::new();

            while let Ok((dir_url, prefix)) = rx.recv().await {
                let url = if dir_url.ends_with('/') {
                    dir_url
                } else {
                    format!("{dir_url}/")
                };

                log.debug(&format!("Fetching directory listing: {url}"));

                let entries: Vec<CaddyEntry> = match async {
                    let resp = client
                        .get(&url)
                        .header("Accept", "application/json")
                        .send()
                        .await?;
                    resp.json().await
                }
                .await
                {
                    Ok(e) => e,
                    Err(e) => {
                        log.error(&format!("Failed to list {url}: {e}"));
                        if in_flight.fetch_sub(1, Ordering::AcqRel) == 1 {
                            tx.close();
                        }
                        continue;
                    }
                };

                let mut new_dirs = 0usize;
                for entry in entries {
                    let name = entry.name.as_deref().unwrap_or("").trim_end_matches('/');
                    if name == "." || name == ".." || name.is_empty() {
                        continue;
                    }
                    let mut url_path = entry.url.as_deref().unwrap_or("").to_string();
                    if let Some(stripped) = url_path.strip_prefix("./") {
                        url_path = stripped.to_string();
                    }
                    let full_path = format!("{prefix}{name}");
                    let full_url = format!("{url}{url_path}");

                    if entry.is_dir {
                        new_dirs += 1;
                        let _ = tx.send((full_url, format!("{full_path}/"))).await;
                    } else {
                        log.debug(&format!("Found file: {full_path} -> {full_url}"));
                        local_files.push((full_path, full_url));
                        counter.fetch_add(1, Ordering::Relaxed);
                    }
                }

                if new_dirs > 0 {
                    in_flight.fetch_add(new_dirs, Ordering::AcqRel);
                }
                if in_flight.fetch_sub(1, Ordering::AcqRel) == 1 {
                    tx.close();
                }
            }

            local_files
        }));
    }

    // Drop our sender so workers can terminate when queue drains
    drop(tx);

    let mut all_files = Vec::new();
    for w in workers {
        if let Ok(local) = w.await {
            all_files.extend(local);
        }
    }
    all_files
}

// ── Spinner ─────────────────────────────────────────────────────────────────

const FRAMES: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

async fn run_spinner(counter: Arc<AtomicUsize>, stop: tokio::sync::watch::Receiver<bool>) {
    let mut i = 0usize;
    loop {
        if *stop.borrow() {
            break;
        }
        let count = counter.load(Ordering::Relaxed);
        eprint!(
            "\r{GREEN}[INFO]{NC} {} Enumerating files... {count} found",
            FRAMES[i % FRAMES.len()]
        );
        i += 1;
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    eprint!("\r\x1b[K");
}

// ── Download ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum DlResult {
    Downloaded,
    Skipped,
    Failed,
}

const MAX_RETRIES: u32 = 3;
const RETRY_DELAYS: &[u64] = &[500, 2000, 5000]; // ms

async fn download_file(
    client: &reqwest::Client,
    file_path: &str,
    url: &str,
    download_dir: &Path,
    metadata_dir: &Path,
    progress: &AtomicUsize,
    total: usize,
    log: &Logger,
) -> DlResult {
    let local_file = download_dir.join(file_path);
    let temp_file = PathBuf::from(format!("{}.tmp", local_file.display()));
    let meta_file = metadata_dir.join(format!("{file_path}.meta"));

    if let Some(parent) = local_file.parent() {
        let _ = fs::create_dir_all(parent).await;
    }

    // Retry loop with exponential backoff
    for attempt in 0..MAX_RETRIES {
        if attempt > 0 {
            let delay = RETRY_DELAYS.get(attempt as usize - 1).copied().unwrap_or(5000);
            log.debug(&format!("[{}/{total}] Retry {attempt} for {file_path} after {delay}ms",
                progress.load(Ordering::Relaxed) + 1));
            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
        }

        let result = download_file_once(
            client,
            file_path,
            url,
            &local_file,
            &temp_file,
            &meta_file,
            progress,
            total,
            log,
        ).await;

        match result {
            DlResult::Downloaded | DlResult::Skipped => return result,
            DlResult::Failed if attempt < MAX_RETRIES - 1 => continue,
            DlResult::Failed => return DlResult::Failed,
        }
    }

    DlResult::Failed
}

async fn download_file_once(
    client: &reqwest::Client,
    file_path: &str,
    url: &str,
    local_file: &Path,
    temp_file: &Path,
    meta_file: &Path,
    progress: &AtomicUsize,
    total: usize,
    log: &Logger,
) -> DlResult {
    let mut req = client.get(url);
    let (cached_etag, cached_lm) = read_metadata(meta_file).await;
    if let Some(ref etag) = cached_etag {
        req = req.header("If-None-Match", etag.as_str());
    }
    if let Some(ref lm) = cached_lm {
        req = req.header("If-Modified-Since", lm.as_str());
    }

    log.trace(&format!("GET {url}"));

    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
            log.error(&format!("[{n}/{total}] Failed to download {file_path}: {e}"));
            return DlResult::Failed;
        }
    };

    let status = resp.status();

    if status == reqwest::StatusCode::NOT_MODIFIED {
        let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
        log.info(&format!("[{n}/{total}] ⏭️  {MAGENTA}Unmodified{NC}: {file_path}"));
        return DlResult::Skipped;
    }

    if !status.is_success() {
        let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
        log.error(&format!("[{n}/{total}] HTTP {status} for {file_path}"));
        return DlResult::Failed;
    }

    let etag = resp
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let last_modified = resp
        .headers()
        .get("last-modified")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    if log.verbose >= 2 {
        log.trace(&format!("HTTP {status} for {file_path}"));
        for (k, v) in resp.headers() {
            if let Ok(val) = v.to_str() {
                log.trace(&format!("  {k}: {val}"));
            }
        }
    }

    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
            log.error(&format!("[{n}/{total}] Failed reading body for {file_path}: {e}"));
            return DlResult::Failed;
        }
    };

    if let Err(e) = fs::write(temp_file, &bytes).await {
        let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
        log.error(&format!("[{n}/{total}] Failed writing {file_path}: {e}"));
        return DlResult::Failed;
    }

    if let Err(e) = fs::rename(temp_file, local_file).await {
        let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
        log.error(&format!("[{n}/{total}] Failed moving {file_path}: {e}"));
        let _ = fs::remove_file(temp_file).await;
        return DlResult::Failed;
    }

    save_metadata(meta_file, &etag, &last_modified).await;

    let n = progress.fetch_add(1, Ordering::Relaxed) + 1;
    log.info(&format!("[{n}/{total}] ⬇️  {GREEN}Downloaded{NC}: {file_path}"));
    DlResult::Downloaded
}

// ── Main ────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let base_url = args.base_url.trim_end_matches('/').to_string();
    let download_dir = PathBuf::from(&args.download_dir);
    let metadata_dir = download_dir.join(".metadata");
    let max_concurrent: usize = std::env::var("PARALLEL_JOBS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(50);

    fs::create_dir_all(&download_dir).await.expect("Failed to create download directory");
    fs::create_dir_all(&metadata_dir).await.expect("Failed to create metadata directory");

    let log = Arc::new(Logger::new(args.verbose));
    log.info(&format!("Starting mirror from {base_url} to {}", download_dir.display()));

    let client = reqwest::Client::builder()
        .user_agent("mirror-caddy/0.1-rust")
        .timeout(std::time::Duration::from_secs(300))
        .connect_timeout(std::time::Duration::from_secs(60))
        .pool_max_idle_per_host(max_concurrent)
        .http2_adaptive_window(true)
        .build()
        .expect("Failed to create HTTP client");

    // ── Enumerate ───────────────────────────────────────────────────────

    let counter = Arc::new(AtomicUsize::new(0));
    let (stop_tx, stop_rx) = tokio::sync::watch::channel(false);

    let spinner_handle = if args.verbose == 0 {
        log.spinner_active.store(true, Ordering::Relaxed);
        let c = counter.clone();
        Some(tokio::spawn(async move { run_spinner(c, stop_rx).await }))
    } else {
        drop(stop_rx);
        None
    };

    let files = enumerate_files(&client, &base_url, &log, &counter, max_concurrent).await;

    if let Some(h) = spinner_handle {
        let _ = stop_tx.send(true);
        let _ = h.await;
        log.spinner_active.store(false, Ordering::Relaxed);
    }

    let total = files.len();
    log.info(&format!("Found {total} files to process"));

    if total == 0 {
        log.info("No files to download");
        return;
    }

    // ── Download ────────────────────────────────────────────────────────

    log.info(&format!("Downloading {total} files with max {max_concurrent} concurrent requests..."));

    let progress = Arc::new(AtomicUsize::new(0));
    let sem = Arc::new(Semaphore::new(max_concurrent));

    let mut handles = Vec::with_capacity(total);

    for (file_path, url) in files {
        let client = client.clone();
        let download_dir = download_dir.clone();
        let metadata_dir = metadata_dir.clone();
        let progress = progress.clone();
        let sem = sem.clone();
        let log = log.clone();

        handles.push(tokio::spawn(async move {
            let Ok(_permit) = sem.acquire().await else {
                return DlResult::Failed;
            };
            download_file(
                &client,
                &file_path,
                &url,
                &download_dir,
                &metadata_dir,
                &progress,
                total,
                &log,
            )
            .await
        }));
    }

    let mut downloaded = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;

    for h in handles {
        match h.await {
            Ok(DlResult::Downloaded) => downloaded += 1,
            Ok(DlResult::Skipped) => skipped += 1,
            _ => failed += 1,
        }
    }

    log.info(&format!("Mirror complete: {downloaded} downloaded, {skipped} unchanged, {failed} failed"));

    if failed > 0 {
        std::process::exit(1);
    }
}
