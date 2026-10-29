use std::fs;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

use harper_core::linting::{Lint, LintGroup, Linter, Suggestion};
use harper_core::parsers::MarkdownOptions;
use harper_core::spell::{FstDictionary, MergedDictionary, MutableDictionary};
use harper_core::{Dialect, DictWordMetadata, Document};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(untagged)]
enum Request {
    Lint { text: String },
    AddWord { add_word: String },
}

#[derive(Serialize)]
struct Issue {
    start: usize,
    end: usize,
    kind: String,
    message: String,
    suggestions: Vec<String>,
}

struct Checker {
    words_file: PathBuf,
    dialect: Dialect,
    dictionary: Arc<MergedDictionary>,
    linter: LintGroup,
}

impl Checker {
    fn new(words_file: PathBuf, dialect: Dialect) -> Self {
        let dictionary = Self::build_dictionary(&words_file);
        let linter = LintGroup::new_curated(dictionary.clone(), dialect);
        Self { words_file, dialect, dictionary, linter }
    }

    fn build_dictionary(words_file: &PathBuf) -> Arc<MergedDictionary> {
        let mut user_words = MutableDictionary::new();
        for word in fs::read_to_string(words_file).unwrap_or_default().lines() {
            let word = word.trim();
            if !word.is_empty() {
                user_words.append_word_str(word, DictWordMetadata::default());
            }
        }
        let mut merged = MergedDictionary::new();
        merged.add_dictionary(FstDictionary::curated());
        merged.add_dictionary(Arc::new(user_words));
        Arc::new(merged)
    }

    fn add_word(&mut self, word: &str) -> io::Result<()> {
        if let Some(parent) = self.words_file.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut file = fs::OpenOptions::new().create(true).append(true).open(&self.words_file)?;
        writeln!(file, "{}", word.trim())?;
        *self = Self::new(self.words_file.clone(), self.dialect);
        Ok(())
    }

    fn lint(&mut self, text: &str) -> Vec<Issue> {
        let document = Document::new_markdown(text, MarkdownOptions::default(), self.dictionary.as_ref());
        let source = document.get_source();
        let utf16_offsets = utf16_offsets(source);
        let mut lints = self.linter.lint(&document);
        lints.sort_by_key(|lint| (lint.span.start, lint.priority));
        let mut covered_until = 0;
        lints.retain(|lint| {
            let keep = lint.span.start >= covered_until;
            if keep {
                covered_until = lint.span.end;
            }
            keep
        });
        lints
            .iter()
            .map(|lint| to_issue(lint, source, &utf16_offsets))
            .collect()
    }
}

fn utf16_offsets(source: &[char]) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(source.len() + 1);
    let mut offset = 0;
    offsets.push(0);
    for c in source {
        offset += c.len_utf16();
        offsets.push(offset);
    }
    offsets
}

fn to_issue(lint: &Lint, source: &[char], utf16_offsets: &[usize]) -> Issue {
    let original: String = source[lint.span.start..lint.span.end].iter().collect();
    let mut suggestions: Vec<String> = Vec::new();
    for suggestion in &lint.suggestions {
        let text = match suggestion {
            Suggestion::ReplaceWith(chars) => chars.iter().collect(),
            Suggestion::InsertAfter(chars) => format!("{original}{}", chars.iter().collect::<String>()),
            Suggestion::Remove => String::new(),
        };
        if !suggestions.contains(&text) {
            suggestions.push(text);
        }
    }
    Issue {
        start: utf16_offsets[lint.span.start],
        end: utf16_offsets[lint.span.end],
        kind: lint.lint_kind.to_string(),
        message: lint.message.clone(),
        suggestions,
    }
}

fn main() {
    let words_file = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .expect("usage: harper-lint <user-dictionary-file> [American|British|Indian|Canadian|Australian]");
    let dialect = match std::env::args().nth(2).as_deref() {
        Some("British") => Dialect::British,
        Some("Indian") => Dialect::Indian,
        Some("Canadian") => Dialect::Canadian,
        Some("Australian") => Dialect::Australian,
        _ => Dialect::American,
    };
    let mut checker = Checker::new(words_file, dialect);
    let stdout = io::stdout();
    let mut out = stdout.lock();

    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(Request::Lint { text }) => serde_json::json!({ "issues": checker.lint(&text) }),
            Ok(Request::AddWord { add_word }) => match checker.add_word(&add_word) {
                Ok(()) => serde_json::json!({ "ok": true }),
                Err(error) => serde_json::json!({ "error": error.to_string() }),
            },
            Err(error) => serde_json::json!({ "error": error.to_string() }),
        };
        if writeln!(out, "{response}").and_then(|_| out.flush()).is_err() {
            break;
        }
    }
}
