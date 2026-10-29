//! Backups of the data folder as one ZIP file, easy to move to a phone or
//! another computer. The ZIP holds the files of the data folder at its root.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};

fn skipped(name: &str) -> bool {
    // The write lock belongs to one device; temporary files are half-written.
    name.starts_with(".datovka-zamek")
        || name.ends_with(".tmp")
        || name.ends_with(".part")
        || name == ".DS_Store"
}

type Zip = zip::ZipWriter<File>;

/// Packs the data folder into `out` and returns the number of files.
/// Message databases an account keeps in another folder (`database_dir`)
/// go in too, beside the others, so a restored archive has everything.
pub fn zip_dir(dir: &Path, out: &Path) -> Result<u64> {
    let mut w = zip::ZipWriter::new(File::create(out)?);
    let mut n = add_tree(&mut w, dir, "")?;
    let store = super::LegacyStore::new(dir);
    let here = std::fs::canonicalize(dir)?;
    for acc in super::conf::load(dir)? {
        // Already in, when it is the archive folder or a folder inside it.
        if std::fs::canonicalize(store.db_dir(&acc)).is_ok_and(|d| d.starts_with(&here)) {
            continue;
        }
        for db in store.message_dbs(&acc)? {
            let name = db.file_name().unwrap_or_default().to_string_lossy().into_owned();
            n += add_file(&mut w, &db, &name)?;
            // Files of high-volume messages beside the database.
            let folder = db.with_extension("");
            if folder.is_dir() {
                let stem = folder.file_name().unwrap_or_default().to_string_lossy().into_owned();
                n += add_tree(&mut w, &folder, &format!("{stem}/"))?;
            }
        }
    }
    w.finish().map_err(zip_err)?;
    Ok(n)
}

fn zip_options() -> zip::write::SimpleFileOptions {
    zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .large_file(true)
}

fn add_file(w: &mut Zip, path: &Path, inner: &str) -> Result<u64> {
    w.start_file(inner, zip_options()).map_err(zip_err)?;
    let mut data = Vec::new();
    File::open(path)?.read_to_end(&mut data)?;
    w.write_all(&data)?;
    Ok(1)
}

/// Adds a folder with everything below it under `prefix`.
fn add_tree(w: &mut Zip, dir: &Path, prefix: &str) -> Result<u64> {
    let mut n = 0;
    let mut stack = vec![(dir.to_path_buf(), prefix.to_string())];
    while let Some((path, prefix)) = stack.pop() {
        for entry in std::fs::read_dir(&path)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if skipped(&name) {
                continue;
            }
            let inner = format!("{prefix}{name}");
            if entry.file_type()?.is_dir() {
                stack.push((entry.path(), format!("{inner}/")));
                continue;
            }
            n += add_file(w, &entry.path(), &inner)?;
        }
    }
    Ok(n)
}

/// Unpacks a backup ZIP into `to` and returns the folder with `dsgui.conf`:
/// `to` itself, or the one folder inside when the ZIP was made from a folder
/// (as Finder or Explorer do).
pub fn unzip_backup(zip_file: &Path, to: &Path) -> Result<PathBuf> {
    let mut archive = zip::ZipArchive::new(File::open(zip_file)?).map_err(zip_err)?;
    std::fs::create_dir_all(to)?;
    for i in 0..archive.len() {
        let mut f = archive.by_index(i).map_err(zip_err)?;
        // Names like "../x" would write outside the folder.
        let Some(rel) = f.enclosed_name() else {
            continue;
        };
        let target = to.join(rel);
        if f.is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut data = Vec::new();
        f.read_to_end(&mut data)?;
        std::fs::write(&target, data)?;
    }
    if to.join("dsgui.conf").exists() {
        return Ok(to.to_path_buf());
    }
    let inner: Vec<PathBuf> = std::fs::read_dir(to)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.join("dsgui.conf").exists())
        .collect();
    match inner.as_slice() {
        [one] => Ok(one.clone()),
        _ => Err(Error::Zfo(
            "v ZIP souboru není záloha Datovky (chybí dsgui.conf)".into(),
        )),
    }
}

fn zip_err(e: zip::result::ZipError) -> Error {
    Error::Zfo(format!("ZIP: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("datovka-zip-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_backup_comes_back_without_the_lock() {
        let data = temp("data");
        std::fs::write(data.join("dsgui.conf"), "[credentials]\n").unwrap();
        std::fs::write(data.join("abc_2026___0.db"), [1u8, 2, 3]).unwrap();
        std::fs::write(data.join(".datovka-zamek.json"), "{}").unwrap();
        std::fs::create_dir_all(data.join("sub")).unwrap();
        std::fs::write(data.join("sub/x.txt"), "x").unwrap();
        let out = temp("out").join("zaloha.zip");
        assert_eq!(zip_dir(&data, &out).unwrap(), 3);

        let back = temp("back");
        let root = unzip_backup(&out, &back).unwrap();
        assert_eq!(root, back);
        assert_eq!(std::fs::read(back.join("abc_2026___0.db")).unwrap(), [1, 2, 3]);
        assert_eq!(std::fs::read_to_string(back.join("sub/x.txt")).unwrap(), "x");
        assert!(!back.join(".datovka-zamek.json").exists());
        for d in [data, out.parent().unwrap().to_path_buf(), back] {
            std::fs::remove_dir_all(d).unwrap();
        }
    }

    #[test]
    fn a_zipped_folder_is_found_inside() {
        let out = temp("finder").join("z.zip");
        let mut w = zip::ZipWriter::new(File::create(&out).unwrap());
        let o = zip::write::SimpleFileOptions::default();
        w.start_file("DATOVKA-zaloha/dsgui.conf", o).unwrap();
        w.write_all(b"[credentials]\n").unwrap();
        w.start_file("../utek.txt", o).unwrap();
        w.write_all(b"ne").unwrap();
        w.finish().unwrap();
        let back = temp("finder-back");
        let root = unzip_backup(&out, &back).unwrap();
        assert_eq!(root, back.join("DATOVKA-zaloha"));
        assert!(!back.parent().unwrap().join("utek.txt").exists());
        std::fs::remove_dir_all(out.parent().unwrap()).unwrap();
        std::fs::remove_dir_all(back).unwrap();
    }
}
