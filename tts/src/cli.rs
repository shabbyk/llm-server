//! Command-line interface.
//!
//! Mirrors the verbs of the shell `tts` it replaces, so muscle memory carries
//! over. `up`/`down`/`status` are the everyday ones.

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "tts",
    version,
    about = "Local Qwen3-TTS server: supervises KoboldCpp and serves the web UI",
    long_about = None,
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Start the server and the web UI, then wait until it is ready
    Up,

    /// Stop the server, and confirm the port and GPU memory were released
    Down,

    /// Stop, then start
    Restart,

    /// Start if stopped, stop if started
    Toggle,

    /// State, model, backend, ports and voices
    Status,

    /// Run in the foreground, supervising the TTS server (for development)
    Serve {
        /// Do not start a TTS server; just front one that is already running
        #[arg(long)]
        attach: bool,
    },

    /// Speak text to a WAV file
    Say {
        /// Text to speak. With no argument, text is read from stdin.
        text: Vec<String>,
        /// Voice name exactly as advertised, extension included
        #[arg(short, long)]
        voice: Option<String>,
        /// Output path (default: $TTS_OUT/<timestamp>.wav)
        #[arg(short, long)]
        out: Option<PathBuf>,
    },

    /// List the voice names the server advertises
    Voices,

    /// Install a reference clip as a new voice, then restart
    Add {
        /// A .wav or .mp3 file to clone
        file: PathBuf,
    },

    /// Follow the wrapper's own log
    Log,

    /// Follow KoboldCpp's log (what `tmux attach` used to be for)
    Watch,
}
