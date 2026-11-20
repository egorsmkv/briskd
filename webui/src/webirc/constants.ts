// IRCv3 tags, vendor capabilities, and limits used by WebIRC.
export const FEATURES_CAP = "egorsmkv.github.io/features";

export const REDACT_CAP = "draft/message-redaction";

export const REACT_TAG = "+draft/react";

export const REPLY_TAG = "+draft/reply";

export const TYPING_TAG = "+typing";

export const EDIT_TAG = "+egorsmkv.github.io/edit";

export const SAFE_MSGID_RE = /^[A-Za-z0-9._-]{1,128}$/;

export const MAX_REACTIONS_PER_MSG = 20;

export const MAX_TYPERS_PER_BUF = 20;

export const QUICK_EMOJIS = ["👍", "❤️", "😂", "🔥"] as const;

export const PASTE_TAG = "+egorsmkv.github.io/paste";

export const PASTE_LANG_TAG = "+egorsmkv.github.io/paste-lang";

export const PASTE_TITLE_TAG = "+egorsmkv.github.io/paste-title";

export const VOICE_CAP = "egorsmkv.github.io/voice";

export const VOICE_TAG = "+egorsmkv.github.io/voice";

export const VOICE_DUR_TAG = "+egorsmkv.github.io/voice-dur";

export const VOICE_ID_RE = /^[0-9a-f]{32}\.(ogg|webm)$/;

export const FILES_CAP = "egorsmkv.github.io/files";

export const FILE_TAG = "+egorsmkv.github.io/file";

export const FILE_NAME_TAG = "+egorsmkv.github.io/file-name";

export const FILE_SIZE_TAG = "+egorsmkv.github.io/file-size";

export const ALBUM_TAG = "+egorsmkv.github.io/album";

export const FILE_ID_RE = /^[0-9a-f]{32}\.[a-z0-9]{1,8}$/;
