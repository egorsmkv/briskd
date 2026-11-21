// The chat page. Its markup is static (TSX components in ./view/); the WebIRC
// controllers in webui/src/webirc/ find the elements by id and drive them.
// The view never re-renders: Preact would otherwise re-apply props such as
// `value` over what the user typed or what the controllers changed.
import { Component } from "preact";
import { AttachDialog } from "./view/AttachDialog.tsx";
import { ChatHeader } from "./view/ChatHeader.tsx";
import { CodeDialog } from "./view/CodeDialog.tsx";
import { Composer } from "./view/Composer.tsx";
import { ConnectView } from "./view/ConnectView.tsx";
import { DiscoverDialog } from "./view/DiscoverDialog.tsx";
import { IncomingCallDialog } from "./view/IncomingCallDialog.tsx";
import { MembersPanel } from "./view/MembersPanel.tsx";
import { MessageArea } from "./view/MessageArea.tsx";
import { ModerationDialog } from "./view/ModerationDialog.tsx";
import { SearchDialog } from "./view/SearchDialog.tsx";
import { SettingsDialog } from "./view/SettingsDialog.tsx";
import { Sidebar } from "./view/Sidebar.tsx";
import { TopicDialog } from "./view/TopicDialog.tsx";

class WebircView extends Component {
  override shouldComponentUpdate(): boolean {
    return false;
  }

  override componentDidMount(): void {
    // Imported after mount: the controllers look their elements up when
    // their modules load.
    void import("../../../webirc/boot.ts").then((m) => m.boot());
  }

  override render() {
    return (
      <>
        <ConnectView />
        <section id="chat-view">
          <div class="drawer-backdrop" id="drawer-backdrop"></div>
          <Sidebar />
          <ChatHeader />
          <MessageArea />
          <Composer />
          <MembersPanel />
        </section>
        <SettingsDialog />
        <TopicDialog />
        <CodeDialog />
        <ModerationDialog />
        <AttachDialog />
        <DiscoverDialog />
        <SearchDialog />
        <IncomingCallDialog />
      </>
    );
  }
}

export default function WebircPage() {
  return <WebircView />;
}
