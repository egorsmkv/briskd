// Single-page app entry: every page of the web UI (chat, sign-up, account
// verification, password recovery, admin) is a route of this app.
import { render } from "preact";
import { App } from "./App.tsx";
import { startRouter } from "./router.ts";

startRouter();
render(<App />, document.getElementById("app")!);
