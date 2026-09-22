import { joinSession } from "@github/copilot-sdk/extension";
import { startManaged } from "./adapter.mjs";

startManaged({ joinSession }).catch(() => {
  console.error("Maestro messaging unavailable for this session; no fallback or retry.");
  process.exit(1);
});
