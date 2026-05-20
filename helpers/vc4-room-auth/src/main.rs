use serde::Deserialize;
use std::env;
use std::fs;
use std::process;

#[derive(Debug, Deserialize)]
struct Config {
    #[serde(default)]
    default: Option<AuthEntry>,
    #[serde(default)]
    rooms: Vec<Room>,
}

#[derive(Debug, Deserialize)]
struct Room {
    id: String,
    username: Option<String>,
    password: Option<String>,
    #[serde(default = "default_targets")]
    targets: Vec<String>,
    #[serde(default)]
    credentials: TargetCredentials,
}

#[derive(Debug, Default, Deserialize)]
struct AuthEntry {
    username: Option<String>,
    password: Option<String>,
    #[serde(default = "default_targets")]
    targets: Vec<String>,
    #[serde(default)]
    credentials: TargetCredentials,
}

#[derive(Debug, Default, Deserialize)]
struct TargetCredentials {
    cws: Option<Credential>,
    xpanel: Option<Credential>,
    html: Option<Credential>,
}

#[derive(Debug, Clone, Deserialize)]
struct Credential {
    username: String,
    password: String,
}

fn default_targets() -> Vec<String> {
    vec!["cws".into(), "xpanel".into(), "html".into()]
}

fn normalize_target(target: &str) -> Option<&'static str> {
    match target.trim().to_ascii_lowercase().as_str() {
        "cws" => Some("cws"),
        "xpanel" => Some("xpanel"),
        "html" => Some("html"),
        _ => None,
    }
}

fn target_credential(credentials: &TargetCredentials, target: &str) -> Option<Credential> {
    match target {
        "cws" => credentials.cws.clone(),
        "xpanel" => credentials.xpanel.clone(),
        "html" => credentials.html.clone(),
        _ => None,
    }
}

fn inherited_credential(
    username: &Option<String>,
    password: &Option<String>,
) -> Option<Credential> {
    Some(Credential {
        username: username.as_ref()?.clone(),
        password: password.as_ref()?.clone(),
    })
}

fn configured_targets(targets: &[String]) -> Vec<&'static str> {
    let mut normalized = Vec::new();
    for target in targets {
        let Some(target) = normalize_target(target) else {
            continue;
        };
        if !normalized.contains(&target) {
            normalized.push(target);
        }
    }
    normalized
}

fn regex_escape(input: &str) -> String {
    let mut escaped = String::new();
    for ch in input.chars() {
        if matches!(
            ch,
            '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '\\' | '|'
        ) {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

fn print_row(kind: &str, room_id: &str, target: &str, credential: Credential) {
    let username = credential.username.trim();
    if room_id.trim().is_empty() || target.is_empty() || username.is_empty() {
        return;
    }
    println!(
        "{kind}\t{}\t{target}\t{username}\t{}\t{}",
        room_id.trim(),
        credential.password,
        regex_escape(room_id.trim())
    );
}

fn main() {
    let path = env::args().nth(1).unwrap_or_else(|| {
        eprintln!("usage: vc4-room-auth <rooms.toml>");
        process::exit(2);
    });

    let input = fs::read_to_string(&path).unwrap_or_else(|err| {
        eprintln!("failed to read {path}: {err}");
        process::exit(1);
    });

    let config: Config = toml::from_str(&input).unwrap_or_else(|err| {
        eprintln!("failed to parse {path}: {err}");
        process::exit(1);
    });

    if let Some(default) = config.default {
        for target in configured_targets(&default.targets) {
            let credential = target_credential(&default.credentials, target)
                .or_else(|| inherited_credential(&default.username, &default.password));
            if let Some(credential) = credential {
                print_row("default", "__default__", target, credential);
            }
        }
    }

    for room in config.rooms {
        let room_id = room.id.trim();
        if room_id.is_empty() {
            continue;
        }

        for target in configured_targets(&room.targets) {
            let credential = target_credential(&room.credentials, target)
                .or_else(|| inherited_credential(&room.username, &room.password));
            if let Some(credential) = credential {
                print_row("room", room_id, target, credential);
            }
        }
    }
}
