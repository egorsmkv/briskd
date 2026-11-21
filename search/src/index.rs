//! The message index: a Tantivy index of the messages briskd keeps in its
//! stored history, one document per message.
//!
//! A document holds the message id briskd assigned (`id`, a conversation and a
//! sequence number), its conversation (`conv`), its time in milliseconds
//! since the epoch (`time`), and its text, tokenized for search. The text is
//! indexed but not stored: the index can match words but cannot return a
//! message's content. briskd loads matching messages from its own history.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tantivy::collector::{Count, TopDocs};
use tantivy::query::{BooleanQuery, Occur, Query, QueryParser, RangeQuery, TermSetQuery};
use tantivy::schema::{FAST, Field, INDEXED, STORED, STRING, Schema, TEXT, Value};
use tantivy::{Index, IndexReader, IndexWriter, Order, ReloadPolicy, TantivyDocument, Term, doc};

/// Writer heap shared by the indexing threads, bytes.
const WRITER_HEAP: usize = 64 * 1024 * 1024;
/// Most conversations one search may name.
pub const MAX_CONVS: usize = 10_000;
/// Most hits one search returns.
pub const MAX_LIMIT: usize = 200;
/// Longest query text, bytes.
pub const MAX_QUERY_BYTES: usize = 500;

/// One change to the index, applied in order by [`MessageIndex::apply`].
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    /// Add a message, replacing any document with the same id.
    Add {
        id: String,
        conv: String,
        time: i64,
        text: String,
    },
    /// Remove the message with this id.
    Delete { id: String },
    /// Remove every message of a conversation.
    DeleteConv { conv: String },
    /// Remove everything (briskd is about to send its whole history).
    Clear,
}

#[derive(Debug, Deserialize)]
pub struct SearchRequest {
    /// The words to find, in Tantivy query syntax (`"exact phrase"`,
    /// `word*`, `-excluded`, `a OR b`); a malformed query is read leniently.
    pub q: String,
    /// Conversations the searcher may read; nothing else can match.
    pub convs: Vec<String>,
    pub limit: usize,
    /// Only messages older than this time (milliseconds), for paging.
    #[serde(default)]
    pub before: Option<i64>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Hit {
    pub id: String,
    pub conv: String,
    pub time: i64,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub hits: Vec<Hit>,
    /// Matches in total, before `limit`.
    pub total: usize,
}

#[derive(Debug)]
pub enum Error {
    Invalid(&'static str),
    Index(tantivy::TantivyError),
}

impl From<tantivy::TantivyError> for Error {
    fn from(e: tantivy::TantivyError) -> Self {
        Error::Index(e)
    }
}

struct Fields {
    id: Field,
    conv: Field,
    time: Field,
    text: Field,
}

pub struct MessageIndex {
    index: Index,
    reader: IndexReader,
    writer: Mutex<IndexWriter>,
    fields: Fields,
    /// Where the index lives on disk (none in memory).
    dir: Option<PathBuf>,
}

fn schema() -> (Schema, Fields) {
    let mut b = Schema::builder();
    let id = b.add_text_field("id", STRING | STORED);
    let conv = b.add_text_field("conv", STRING | STORED);
    let time = b.add_i64_field("time", INDEXED | STORED | FAST);
    // The default tokenizer splits on non-alphanumeric characters (any
    // script) and lowercases, so it serves Latin, Cyrillic, and the rest
    // without language-specific stemming.
    let text = b.add_text_field("text", TEXT);
    (
        b.build(),
        Fields {
            id,
            conv,
            time,
            text,
        },
    )
}

impl MessageIndex {
    /// Open the index in `dir`, creating it when empty.
    pub fn open(dir: &Path) -> Result<Self, Error> {
        std::fs::create_dir_all(dir).map_err(|e| Error::Index(e.into()))?;
        let (schema, fields) = schema();
        let directory = tantivy::directory::MmapDirectory::open(dir)
            .map_err(|e| Error::Index(tantivy::TantivyError::from(e)))?;
        let index = Index::open_or_create(directory, schema)?;
        let mut ix = Self::with_index(index, fields)?;
        ix.dir = Some(dir.to_path_buf());
        Ok(ix)
    }

    /// An index held in memory (tests).
    #[cfg(test)]
    pub fn in_memory() -> Result<Self, Error> {
        let (schema, fields) = schema();
        Self::with_index(Index::create_in_ram(schema), fields)
    }

    fn with_index(index: Index, fields: Fields) -> Result<Self, Error> {
        let writer = index.writer(WRITER_HEAP)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        Ok(Self {
            index,
            reader,
            writer: Mutex::new(writer),
            fields,
            dir: None,
        })
    }

    /// Apply `ops` in order and commit once, so a search after this returns
    /// sees all of them.
    pub fn apply(&self, ops: Vec<Op>) -> Result<(), Error> {
        let mut writer = self.writer.lock().expect("index writer lock poisoned");
        for op in ops {
            match op {
                Op::Add {
                    id,
                    conv,
                    time,
                    text,
                } => {
                    writer.delete_term(Term::from_field_text(self.fields.id, &id));
                    writer.add_document(doc!(
                        self.fields.id => id,
                        self.fields.conv => conv,
                        self.fields.time => time,
                        self.fields.text => text,
                    ))?;
                }
                Op::Delete { id } => {
                    writer.delete_term(Term::from_field_text(self.fields.id, &id));
                }
                Op::DeleteConv { conv } => {
                    writer.delete_term(Term::from_field_text(self.fields.conv, &conv));
                }
                Op::Clear => {
                    writer.delete_all_documents()?;
                }
            }
        }
        writer.commit()?;
        drop(writer);
        self.reader.reload()?;
        Ok(())
    }

    /// Messages in `convs` that match `q`, newest first.
    pub fn search(&self, req: &SearchRequest) -> Result<SearchResponse, Error> {
        if req.q.trim().is_empty() || req.q.len() > MAX_QUERY_BYTES {
            return Err(Error::Invalid("query"));
        }
        if req.convs.len() > MAX_CONVS {
            return Err(Error::Invalid("convs"));
        }
        if req.limit == 0 || req.limit > MAX_LIMIT {
            return Err(Error::Invalid("limit"));
        }
        if req.convs.is_empty() {
            return Ok(SearchResponse {
                hits: Vec::new(),
                total: 0,
            });
        }
        let mut parser = QueryParser::for_index(&self.index, vec![self.fields.text]);
        // Every word must match unless the query says OR.
        parser.set_conjunction_by_default();
        let (text_query, _errors) = parser.parse_query_lenient(&req.q);
        let convs = TermSetQuery::new(
            req.convs
                .iter()
                .map(|c| Term::from_field_text(self.fields.conv, c)),
        );
        let mut clauses: Vec<(Occur, Box<dyn Query>)> =
            vec![(Occur::Must, text_query), (Occur::Must, Box::new(convs))];
        if let Some(before) = req.before {
            let upper = Term::from_field_i64(self.fields.time, before);
            clauses.push((
                Occur::Must,
                Box::new(RangeQuery::new(
                    std::ops::Bound::Unbounded,
                    std::ops::Bound::Excluded(upper),
                )),
            ));
        }
        let query = BooleanQuery::new(clauses);
        let searcher = self.reader.searcher();
        let top = TopDocs::with_limit(req.limit).order_by_fast_field::<i64>("time", Order::Desc);
        let (docs, total) = searcher.search(&query, &(top, Count))?;
        let mut hits = Vec::with_capacity(docs.len());
        for (_time, address) in docs {
            let doc: TantivyDocument = searcher.doc(address)?;
            let text = |f: Field| {
                doc.get_first(f)
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            };
            hits.push(Hit {
                id: text(self.fields.id),
                conv: text(self.fields.conv),
                time: doc
                    .get_first(self.fields.time)
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0),
            });
        }
        Ok(SearchResponse { hits, total })
    }

    /// Documents in the index.
    pub fn len(&self) -> u64 {
        self.reader.searcher().num_docs()
    }

    /// Segments the index is made of (merged in the background).
    pub fn segments(&self) -> usize {
        self.reader.searcher().segment_readers().len()
    }

    /// Bytes the index takes on disk (0 in memory): every file in its
    /// directory, including those of segments awaiting garbage collection.
    pub fn disk_bytes(&self) -> u64 {
        let Some(dir) = &self.dir else { return 0 };
        std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .filter_map(|e| e.metadata().ok())
                    .filter(|m| m.is_file())
                    .map(|m| m.len())
                    .sum()
            })
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(id: &str, conv: &str, time: i64, text: &str) -> Op {
        Op::Add {
            id: id.into(),
            conv: conv.into(),
            time,
            text: text.into(),
        }
    }

    fn search(ix: &MessageIndex, q: &str, convs: &[&str]) -> Vec<String> {
        let req = SearchRequest {
            q: q.into(),
            convs: convs.iter().map(|c| c.to_string()).collect(),
            limit: 50,
            before: None,
        };
        ix.search(&req)
            .unwrap()
            .hits
            .into_iter()
            .map(|h| h.id)
            .collect()
    }

    fn sample() -> MessageIndex {
        let ix = MessageIndex::in_memory().unwrap();
        ix.apply(vec![
            add("c #dev 1", "c #dev", 1000, "the deploy failed on staging"),
            add("c #dev 2", "c #dev", 2000, "Deploy fixed, rolling out"),
            add("c #ops 1", "c #ops", 1500, "deploy window is tonight"),
            add(
                "d a:ann a:bob 1",
                "d a:ann a:bob",
                1200,
                "Привіт, деплой готовий",
            ),
        ])
        .unwrap();
        ix
    }

    #[test]
    fn matches_only_the_allowed_conversations_newest_first() {
        let ix = sample();
        assert_eq!(
            search(&ix, "deploy", &["c #dev"]),
            vec!["c #dev 2", "c #dev 1"]
        );
        assert_eq!(
            search(&ix, "deploy", &["c #dev", "c #ops"]),
            vec!["c #dev 2", "c #ops 1", "c #dev 1"]
        );
        assert!(search(&ix, "deploy", &[]).is_empty());
        assert!(search(&ix, "deploy", &["c #nowhere"]).is_empty());
    }

    #[test]
    fn words_are_case_insensitive_in_any_script_and_all_must_match() {
        let ix = sample();
        assert_eq!(
            search(&ix, "ДЕПЛОЙ", &["d a:ann a:bob"]),
            vec!["d a:ann a:bob 1"]
        );
        assert_eq!(search(&ix, "deploy staging", &["c #dev"]), vec!["c #dev 1"]);
        assert_eq!(
            search(&ix, "deploy OR window", &["c #ops"]),
            vec!["c #ops 1"]
        );
        assert_eq!(
            search(&ix, "\"rolling out\"", &["c #dev"]),
            vec!["c #dev 2"]
        );
        // A malformed query is read leniently rather than rejected.
        assert_eq!(search(&ix, "deploy AND (", &["c #ops"]), vec!["c #ops 1"]);
    }

    #[test]
    fn add_replaces_and_deletes_remove() {
        let ix = sample();
        ix.apply(vec![add("c #dev 1", "c #dev", 1000, "edited text")])
            .unwrap();
        assert_eq!(search(&ix, "deploy", &["c #dev"]), vec!["c #dev 2"]);
        assert_eq!(search(&ix, "edited", &["c #dev"]), vec!["c #dev 1"]);
        ix.apply(vec![Op::Delete {
            id: "c #dev 2".into(),
        }])
        .unwrap();
        assert!(search(&ix, "deploy", &["c #dev"]).is_empty());
        ix.apply(vec![Op::DeleteConv {
            conv: "c #ops".into(),
        }])
        .unwrap();
        assert!(search(&ix, "deploy", &["c #ops"]).is_empty());
        assert_eq!(ix.len(), 2);
        ix.apply(vec![Op::Clear]).unwrap();
        assert_eq!(ix.len(), 0);
    }

    #[test]
    fn reports_its_size_on_disk() {
        let dir = std::env::temp_dir().join(format!("briskd-search-test-{}", std::process::id()));
        let ix = MessageIndex::open(&dir).unwrap();
        assert_eq!(ix.segments(), 0);
        ix.apply(vec![add("c #a 1", "c #a", 1, "hello world")])
            .unwrap();
        assert_eq!(ix.len(), 1);
        assert_eq!(ix.segments(), 1);
        assert!(ix.disk_bytes() > 0);
        drop(ix);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn before_pages_back_and_limits_are_checked() {
        let ix = sample();
        let req = SearchRequest {
            q: "deploy".into(),
            convs: vec!["c #dev".into(), "c #ops".into()],
            limit: 1,
            before: Some(2000),
        };
        let res = ix.search(&req).unwrap();
        assert_eq!(
            res.hits,
            vec![Hit {
                id: "c #ops 1".into(),
                conv: "c #ops".into(),
                time: 1500
            }]
        );
        assert_eq!(res.total, 2);
        for bad in [
            SearchRequest {
                q: " ".into(),
                convs: vec![],
                limit: 1,
                before: None,
            },
            SearchRequest {
                q: "x".into(),
                convs: vec![],
                limit: 0,
                before: None,
            },
            SearchRequest {
                q: "x".repeat(MAX_QUERY_BYTES + 1),
                convs: vec![],
                limit: 1,
                before: None,
            },
        ] {
            assert!(matches!(ix.search(&bad), Err(Error::Invalid(_))));
        }
    }
}
