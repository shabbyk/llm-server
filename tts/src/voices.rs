//! Voice bookkeeping: what the server advertises, what is on disk, and how the
//! two disagree.
//!
//! The central subtlety is that KoboldCpp builds its voice bank once, at
//! startup, and caches the audio in memory:
//!
//!     # koboldcpp.py:13223
//!     if args.ttsdir and os.path.isdir(args.ttsdir):
//!         for filename in os.listdir(args.ttsdir):     # scanned once, never again
//!
//! So "the server advertises this name" and "a file exists" are independent, and
//! both combinations occur:
//!
//!   * file present, advertised            -> cloned
//!   * no file, not advertised             -> built-in speaker
//!   * no file, but advertised             -> stale: the clip was deleted and the
//!                                            server has not restarted, so it
//!                                            still synthesises from its cache
//!
//! Only `.wav` and `.mp3` can ever be clones, because that is the literal test
//! in KoboldCpp's scanner. That single fact is what makes the stale/built-in
//! distinction decidable.

use serde::Serialize;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Suffixes KoboldCpp's `ttsdir` scanner will actually load.
pub const ALLOWED_SUFFIXES: [&str; 2] = ["wav", "mp3"];

/// Does this advertised name look like a reference clip rather than a built-in?
/// Extension-based, because extension-less names are always built-in speakers.
fn looks_like_clone(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| ALLOWED_SUFFIXES.iter().any(|s| e.eq_ignore_ascii_case(s)))
        .unwrap_or(false)
}

#[derive(Debug, Serialize)]
pub struct VoiceInfo {
    pub name: String,
    /// A reference file is present on disk.
    pub cloned: bool,
    /// A built-in speaker: no file, and not a filename-shaped entry.
    pub builtin: bool,
    /// Advertised with an audio extension but the file is gone. Still generates
    /// audio until the server restarts.
    pub stale: bool,
    /// Length in seconds, when it can be determined (WAV only; `null` for mp3).
    pub duration: Option<f64>,
}

/// Describe each advertised voice against the voices directory.
pub fn describe(voices_dir: &Path, names: &[String]) -> Vec<VoiceInfo> {
    names
        .iter()
        .map(|name| {
            let path = voices_dir.join(name);
            let exists = path.is_file();
            let clone_shaped = looks_like_clone(name);
            VoiceInfo {
                name: name.clone(),
                cloned: exists,
                builtin: !exists && !clone_shaped,
                stale: !exists && clone_shaped,
                duration: if exists { wav_duration(&path) } else { None },
            }
        })
        .collect()
}

/// Turn an upload's filename into something safe to write.
///
/// The extension is preserved deliberately: the advertised voice name IS the
/// filename including extension, so dropping it would produce a voice nobody can
/// select. Returns `None` when nothing usable survives sanitisation.
pub fn sanitize_filename(name: &str) -> Option<String> {
    // Take the basename only — a multipart filename may carry a path.
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let cleaned: String = base
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let cleaned = cleaned.trim_start_matches('.');
    let stem = cleaned.split('.').next().unwrap_or("");
    if stem.is_empty() {
        None
    } else {
        Some(cleaned.to_string())
    }
}

/// Duration of a PCM WAV file, in seconds.
///
/// Hand-parsed rather than pulling in a decoder: we only need the `fmt` and
/// `data` chunk sizes, and the files here are plain PCM straight from the model.
/// Returns `None` for anything that does not parse — including mp3, which is
/// accepted as a voice but not measurable this way.
pub fn wav_duration(path: &Path) -> Option<f64> {
    let mut f = File::open(path).ok()?;
    wav_duration_reader(&mut f)
}

/// As `wav_duration`, for audio held in memory (a synthesis response).
pub fn wav_duration_bytes(data: &[u8]) -> Option<f64> {
    let mut cursor = std::io::Cursor::new(data);
    wav_duration_reader(&mut cursor)
}

fn wav_duration_reader<R: Read + Seek>(f: &mut R) -> Option<f64> {
    let mut header = [0u8; 12];
    f.read_exact(&mut header).ok()?;
    if &header[0..4] != b"RIFF" || &header[8..12] != b"WAVE" {
        return None;
    }

    let mut channels = 0u16;
    let mut sample_rate = 0u32;
    let mut bits = 0u16;
    let mut data_len: Option<u32> = None;

    // Walk the chunk list. Each chunk is a 4-byte id, a 4-byte little-endian
    // length, then the payload, padded to an even length.
    loop {
        let mut chunk = [0u8; 8];
        if f.read_exact(&mut chunk).is_err() {
            break;
        }
        let id = &chunk[0..4];
        let len = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);

        match id {
            b"fmt " => {
                let mut fmt = vec![0u8; len as usize];
                f.read_exact(&mut fmt).ok()?;
                if fmt.len() >= 16 {
                    channels = u16::from_le_bytes([fmt[2], fmt[3]]);
                    sample_rate =
                        u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]);
                    bits = u16::from_le_bytes([fmt[14], fmt[15]]);
                }
            }
            b"data" => {
                data_len = Some(len);
                break;
            }
            _ => {
                // Skip the payload (plus padding if odd).
                let skip = len + (len & 1);
                f.seek(SeekFrom::Current(skip as i64)).ok()?;
            }
        }
    }

    let data_len = data_len?;
    let bytes_per_frame = channels as u32 * (bits as u32 / 8);
    if bytes_per_frame == 0 || sample_rate == 0 {
        return None;
    }
    let seconds = data_len as f64 / (sample_rate as f64 * bytes_per_frame as f64);
    Some((seconds * 100.0).round() / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_paths_and_junk() {
        assert_eq!(sanitize_filename("my voice.wav").as_deref(), Some("my_voice.wav"));
        assert_eq!(sanitize_filename("../../etc/passwd").as_deref(), Some("passwd"));
        assert_eq!(sanitize_filename("a b!.mp3").as_deref(), Some("a_b_.mp3"));
        assert_eq!(sanitize_filename("...").as_deref(), None);
        assert_eq!(sanitize_filename("").as_deref(), None);
    }

    #[test]
    fn distinguishes_clone_shapes() {
        assert!(looks_like_clone("ref.wav"));
        assert!(looks_like_clone("ref.MP3"));
        assert!(!looks_like_clone("kobo"));
        assert!(!looks_like_clone("instruct"));
    }
}
