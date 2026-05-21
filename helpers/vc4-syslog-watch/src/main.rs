#[cfg(unix)]
mod unix;

#[cfg(unix)]
fn main() -> std::io::Result<()> {
    unix::main()
}

#[cfg(not(unix))]
fn main() {
    eprintln!("vc4-syslog-watch is only used inside the Linux VC4 container");
}
