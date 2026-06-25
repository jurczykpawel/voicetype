import {
  List,
  ActionPanel,
  Action,
  Icon,
  Clipboard,
  closeMainWindow,
  showToast,
  Toast,
  LocalStorage,
  confirmAlert,
  Alert,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { HistoryItem, HISTORY_KEY } from "./toggle";

export default function History() {
  const [items, setItems] = useState<HistoryItem[]>([]);
  const [loading, setLoading] = useState(true);

  async function load() {
    const raw = await LocalStorage.getItem<string>(HISTORY_KEY);
    setItems(raw ? JSON.parse(raw) : []);
    setLoading(false);
  }

  useEffect(() => {
    load();
  }, []);

  async function persist(next: HistoryItem[]) {
    setItems(next);
    await LocalStorage.setItem(HISTORY_KEY, JSON.stringify(next));
  }

  async function remove(index: number) {
    await persist(items.filter((_, i) => i !== index));
  }

  async function clearAll() {
    const ok = await confirmAlert({
      title: "Clear all transcripts?",
      primaryAction: { title: "Clear", style: Alert.ActionStyle.Destructive },
    });
    if (ok) await persist([]);
  }

  async function pasteText(text: string) {
    await Clipboard.paste(text);
    await closeMainWindow();
    await showToast({ style: Toast.Style.Success, title: "Pasted" });
  }

  return (
    <List
      isLoading={loading}
      searchBarPlaceholder="Search transcripts…"
      isShowingDetail
    >
      {items.length === 0 ? (
        <List.EmptyView
          icon={Icon.Microphone}
          title="No transcripts yet"
          description="Run Toggle Dictation to start."
        />
      ) : (
        items.map((item, index) => (
          <List.Item
            key={item.date}
            title={
              item.text.length > 60 ? item.text.slice(0, 60) + "…" : item.text
            }
            accessories={[{ date: new Date(item.date) }]}
            detail={<List.Item.Detail markdown={item.text} />}
            actions={
              <ActionPanel>
                <Action
                  title="Paste to Active App"
                  icon={Icon.Clipboard}
                  onAction={() => pasteText(item.text)}
                />
                <Action.CopyToClipboard title="Copy" content={item.text} />
                <Action
                  title="Delete"
                  icon={Icon.Trash}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ["ctrl"], key: "x" }}
                  onAction={() => remove(index)}
                />
                <Action
                  title="Clear All"
                  icon={Icon.Trash}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ["cmd", "shift"], key: "x" }}
                  onAction={clearAll}
                />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
