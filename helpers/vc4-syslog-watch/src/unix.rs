use std::env;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixDatagram;
use std::process::Command;
use std::time::{Duration, Instant};

const DEFAULT_SOCKET: &str = "/dev/log";
const REBOOT_MESSAGE: &str = "AppWatchdog: Received SYS_EVENT_REBOOT";
const CONTINUING_MESSAGE: &str = "AppWatchdog: Received SYS_EVENT_REBOOT but continuing";
const DEFAULT_RESTART_COMMAND: &str = "/usr/local/sbin/vc4-container-restart-launch.sh";

pub fn main() -> io::Result<()> {
    let socket_path = env::var("VC4_SYSLOG_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.to_string());
    let restart_command = env::var("VC4_REBOOT_EVENT_RESTART_COMMAND")
        .unwrap_or_else(|_| DEFAULT_RESTART_COMMAND.to_string());
    let debounce = Duration::from_secs(
        env::var("VC4_REBOOT_EVENT_DEBOUNCE_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(60),
    );

    let _ = fs::remove_file(&socket_path);
    let socket = UnixDatagram::bind(&socket_path)?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o666))?;

    eprintln!("[vc4-syslog-watch] listening on {socket_path}");

    let mut buffer = vec![0_u8; 64 * 1024];
    let mut last_restart: Option<Instant> = None;

    loop {
        let size = socket.recv(&mut buffer)?;
        let message = String::from_utf8_lossy(&buffer[..size]).into_owned();
        eprintln!("[syslog] {}", message.trim_end_matches('\0').trim_end());

        if message.contains(REBOOT_MESSAGE) && !message.contains(CONTINUING_MESSAGE) {
            continue;
        }

        if message.contains(CONTINUING_MESSAGE) {
            let should_restart = last_restart
                .map(|last| last.elapsed() >= debounce)
                .unwrap_or(true);

            if should_restart {
                last_restart = Some(Instant::now());
                eprintln!(
                    "[vc4-syslog-watch] AppWatchdog reboot event received; launching VC4 restart"
                );
                match Command::new(&restart_command).spawn() {
                    Ok(_) => {}
                    Err(error) => {
                        eprintln!("[vc4-syslog-watch] failed to launch {restart_command}: {error}")
                    }
                }
            }
        }
    }
}
