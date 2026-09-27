use std::collections::BTreeMap;
use std::env;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use zipatch::util::SqexFileStreamStore;
use zipatch::{Platform, ZiPatchChunk, ZiPatchConfig, ZiPatchError, ZiPatchFile};

fn usage() -> ! {
    eprintln!("usage: zipatch-helper apply PATCH GAME_ROOT");
    eprintln!("       zipatch-helper diagnose PATCH GAME_ROOT");
    eprintln!("       zipatch-helper diagnose --apply PATCH GAME_ROOT");
    std::process::exit(64);
}

fn apply_config(game_root: &Path) -> ZiPatchConfig {
    ZiPatchConfig::builder(game_root)
        .platform(Platform::Win32)
        .store(SqexFileStreamStore::new())
        .build()
}

fn apply_patch(patch: &Path, game_root: &Path) -> Result<(), ZiPatchError> {
    let mut patch_file = ZiPatchFile::from_path(patch)?;
    let mut config = apply_config(game_root);
    for chunk in patch_file.chunks() {
        let mut chunk = chunk?;
        chunk.apply(&mut config)?;
    }
    Ok(())
}

fn require_paths(
    patch: impl Into<PathBuf>,
    game_root: impl Into<PathBuf>,
) -> Result<(PathBuf, PathBuf), ExitCode> {
    let patch = patch.into();
    let game_root = game_root.into();
    if !patch.is_file() || !game_root.is_dir() {
        eprintln!("patch or game root is unavailable");
        return Err(ExitCode::from(66));
    }
    Ok((patch, game_root))
}

fn print_context(patch: &Path, game_root: &Path) {
    let size = patch.metadata().map(|meta| meta.len()).unwrap_or(0);
    println!("patch: {}", patch.display());
    println!("size: {size}");
    println!("game_root: {}", game_root.display());
}

fn print_header(patch_file: &ZiPatchFile<File>) {
    let header = patch_file.header();
    println!("format_version: {}", header.version);
    println!("patch_type: {}", header.patch_type);
    println!("repository_id: {}", header.repository_name);
}

fn print_counts(counts: &BTreeMap<String, usize>, sqpk: &BTreeMap<char, usize>) {
    println!("chunk_counts:");
    for (chunk_type, count) in counts {
        println!("  {chunk_type}: {count}");
        if chunk_type == "SQPK" {
            for (command, count) in sqpk {
                println!("  SQPK {command}: {count}");
            }
        }
    }
}

fn peek_chunk(path: &Path, index: usize) -> Option<(String, Option<char>)> {
    let mut file = File::open(path).ok()?;
    // ZiPatchFile consumes a 12-byte magic, then chunks of
    // [u32be size][4-byte type][size bytes][u32be crc].
    file.seek(SeekFrom::Start(12)).ok()?;
    for current in 0..=index {
        let mut size_buf = [0u8; 4];
        file.read_exact(&mut size_buf).ok()?;
        let size = u32::from_be_bytes(size_buf);
        let mut type_buf = [0u8; 4];
        file.read_exact(&mut type_buf).ok()?;
        if current == index {
            let chunk_type = String::from_utf8_lossy(&type_buf)
                .trim_end_matches('\0')
                .to_string();
            let command = if chunk_type == "SQPK" && size >= 5 {
                let mut command_buf = [0u8; 5];
                file.read_exact(&mut command_buf).ok()?;
                let byte = command_buf[4];
                if byte.is_ascii() && !byte.is_ascii_control() {
                    Some(byte as char)
                } else {
                    None
                }
            } else {
                None
            };
            return Some((chunk_type, command));
        }
        let skip = u64::from(size) + 4;
        file.seek(SeekFrom::Current(i64::try_from(skip).ok()?))
            .ok()?;
    }
    None
}

fn print_read_error(patch: &Path, index: usize, err: &ZiPatchError) {
    let (chunk_type, command) =
        peek_chunk(patch, index).unwrap_or_else(|| ("unknown".to_string(), None));
    println!("read_error:");
    println!("  chunk_index: {index}");
    println!("  chunk_type: {chunk_type}");
    if let Some(command) = command {
        println!("  sqpk_command: {command}");
    }
    println!("  error: {err}");
}

fn diagnose_parse(patch: &Path, game_root: &Path) -> ExitCode {
    println!("mode: parse");
    print_context(patch, game_root);
    let mut patch_file = match ZiPatchFile::from_path(patch) {
        Ok(patch_file) => patch_file,
        Err(err) => {
            println!("read_error:");
            if !matches!(err, ZiPatchError::InvalidMagic(_)) {
                if let Some((chunk_type, command)) = peek_chunk(patch, 0) {
                    println!("  chunk_index: 0");
                    println!("  chunk_type: {chunk_type}");
                    if let Some(command) = command {
                        println!("  sqpk_command: {command}");
                    }
                }
            }
            println!("  error: {err}");
            return ExitCode::from(1);
        }
    };
    print_header(&patch_file);

    let mut counts = BTreeMap::new();
    let mut sqpk = BTreeMap::new();
    for (index, chunk) in patch_file.chunks().enumerate() {
        match chunk {
            Ok(chunk) => {
                if let ZiPatchChunk::Sqpk(command) = &chunk {
                    *sqpk.entry(command.command_char()).or_insert(0) += 1;
                }
                let chunk_type = chunk.chunk_type().to_string();
                *counts.entry(chunk_type).or_insert(0) += 1;
            }
            Err(err) => {
                print_counts(&counts, &sqpk);
                print_read_error(patch, index, &err);
                return ExitCode::from(1);
            }
        }
    }
    print_counts(&counts, &sqpk);
    println!("parse: ok");
    ExitCode::SUCCESS
}

fn diagnose_apply(patch: &Path, game_root: &Path) -> ExitCode {
    println!("mode: apply");
    print_context(patch, game_root);
    let mut patch_file = match ZiPatchFile::from_path(patch) {
        Ok(patch_file) => patch_file,
        Err(err) => {
            println!("read_error:");
            println!("  error: {err}");
            return ExitCode::from(1);
        }
    };
    print_header(&patch_file);

    let mut config = apply_config(game_root);
    let mut applied = 0usize;
    for (index, chunk) in patch_file.chunks().enumerate() {
        let mut chunk = match chunk {
            Ok(chunk) => chunk,
            Err(err) => {
                print_read_error(patch, index, &err);
                if index > 0 {
                    println!("  note: chunks before this index were already written");
                }
                return ExitCode::from(1);
            }
        };
        let chunk_type = chunk.chunk_type();
        let command = match &chunk {
            ZiPatchChunk::Sqpk(command) => Some(command.command_char()),
            _ => None,
        };
        let summary = chunk.to_string();
        if let Err(err) = chunk.apply(&mut config) {
            println!("apply_error:");
            println!("  chunk_index: {index}");
            println!("  chunk_type: {chunk_type}");
            if let Some(command) = command {
                println!("  sqpk_command: {command}");
            }
            println!("  summary: {summary}");
            println!("  error: {err}");
            if index > 0 {
                println!("  note: chunks before this index were already written");
            }
            return ExitCode::from(1);
        }
        applied += 1;
    }
    println!("apply: ok");
    println!("chunks_applied: {applied}");
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let mut args = env::args_os().skip(1);
    let Some(command) = args.next() else { usage() };

    if command == "apply" {
        let Some(patch) = args.next() else { usage() };
        let Some(game_root) = args.next() else {
            usage()
        };
        if args.next().is_some() {
            usage();
        }
        let (patch, game_root) = match require_paths(patch, game_root) {
            Ok(paths) => paths,
            Err(code) => return code,
        };
        return match apply_patch(&patch, &game_root) {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("ZiPatch apply failed: {err}");
                ExitCode::from(1)
            }
        };
    }

    if command == "diagnose" {
        let Some(next) = args.next() else { usage() };
        let (apply, patch, game_root) = if next == "--apply" {
            let Some(patch) = args.next() else { usage() };
            let Some(game_root) = args.next() else {
                usage()
            };
            (true, patch, game_root)
        } else {
            let Some(game_root) = args.next() else {
                usage()
            };
            (false, next, game_root)
        };
        if args.next().is_some() {
            usage();
        }
        let (patch, game_root) = match require_paths(patch, game_root) {
            Ok(paths) => paths,
            Err(code) => return code,
        };
        return if apply {
            diagnose_apply(&patch, &game_root)
        } else {
            diagnose_parse(&patch, &game_root)
        };
    }

    usage();
}
