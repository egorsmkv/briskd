// Start the WebIRC controllers. Each module's init() wires its part of the
// page (found by element id), in this order. Called once, after the chat
// view's markup is in the DOM (app/pages/webirc/WebircPage.tsx).
import { init as init_settings } from "./settings.ts";
import { init as init_session } from "./session.ts";
import { init as init_calls_ui } from "./calls_ui.ts";
import { init as init_call_settings_ui } from "./call_settings_ui.ts";
import { init as init_e2ee_ui } from "./e2ee_ui.ts";
import { init as init_buffers } from "./buffers.ts";
import { init as init_dm_cache } from "./dm_cache.ts";
import { init as init_sidebar } from "./sidebar.ts";
import { init as init_connection } from "./connection.ts";
import { init as init_login } from "./login.ts";
import { init as init_modals } from "./modals.ts";
import { init as init_composer } from "./composer.ts";
import { init as init_message_actions } from "./message_actions.ts";
import { init as init_typing } from "./typing.ts";
import { init as init_voice } from "./voice.ts";
import { init as init_files } from "./files.ts";
import { init as init_layout } from "./layout.ts";
import { init as init_chat_scroll } from "./chat/scroll.ts";
import { init as init_chat_actions } from "./chat/actions.ts";
import { init as init_mention_picker } from "./mention_picker.ts";

let started = false;

export function boot(): void {
  if (started) return;
  started = true;
  init_settings();
  init_session();
  init_calls_ui();
  init_call_settings_ui();
  init_e2ee_ui();
  init_buffers();
  init_dm_cache();
  init_sidebar();
  init_connection();
  init_login();
  init_modals();
  init_composer();
  init_message_actions();
  init_typing();
  init_voice();
  init_files();
  init_layout();
  init_chat_scroll();
  init_chat_actions();
  init_mention_picker();
}
