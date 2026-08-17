use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

fn usage() -> ! {
    eprintln!("usage: zipatch-helper apply PATCH GAME_ROOT");
    std::process::exit(64);
}

fn main() -> ExitCode {
    let mut args = env::args_os();
    let _program = args.next();
    let Some(command) = args.next() else { usage() };
    let Some(patch) = args.next() else { usage() };
    let Some(game_root) = args.next() else { usage() };
    if args.next().is_some() || command != "apply" {
        usage();
    }

    let patch = PathBuf::from(patch);
    let game_root = PathBuf::from(game_root);
    if !patch.is_file() || !game_root.is_dir() {
        eprintln!("patch or game root is unavailable");
        return ExitCode::from(66);
    }

    match zipatch_rs::apply_patch_file(&patch, &game_root) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => {
            eprintln!("ZiPatch apply failed");
            ExitCode::from(1)
        }
    }
}
