const moods = ["happy", "celebrating", "confused", "clear", "preview", "cancel-preview"];

export const moodSpec = {
  name: "maestro_mood",
  description: "Optionally self-report happy after a verified good outcome, celebrating for a significant win, or confused about missing/conflicting meaning; clear withdraws it. Only on explicit human request, preview shows all 15 cosmetic expressions for 5 seconds each (75 seconds); cancel-preview restores ordinary resolution. Exact own session only. Never ordinary errors or a substitute for a question or failure. Cosmetic only, not task-success evidence. Refusals are not queued or retried.",
  parameters: {
    type: "object", properties: { mood: { type: "string", enum: moods } },
    required: ["mood"], additionalProperties: false,
  },
};

export function moodTool({ own, ownAddress, session, currentBinding, reportMood, controller, signal }) {
  return {
    ...moodSpec,
    handler: async (args, invocation) => {
      try {
        signal?.throwIfAborted();
        if (session()?.sessionId !== own.sessionId || invocation?.sessionId !== own.sessionId) {
          throw new Error("mood-identity-unverified");
        }
        if (!args || typeof args !== "object" || Array.isArray(args) ||
            Object.keys(args).length !== 1 || !Object.hasOwn(args, "mood") || !moods.includes(args.mood)) {
          throw new Error("mood-input-invalid");
        }
        try {
          await currentBinding();
        } catch {
          throw new Error("mood-identity-unverified");
        }
        signal?.throwIfAborted();
        const result = await reportMood({
          identity: { nodeId: own.nodeId, ...ownAddress, capability: own.capability }, mood: args.mood,
        }, controller, signal);
        if (!result || typeof result !== "object" || Array.isArray(result) ||
            Object.keys(result).sort().join(",") !== "changed,mood,ok,sequence,sessionId" ||
            result.ok !== true || result.sessionId !== own.sessionId || result.mood !== args.mood ||
            !Number.isSafeInteger(result.sequence) || result.sequence < 1 || typeof result.changed !== "boolean") {
          throw new Error("mood-unavailable");
        }
        return JSON.stringify(result);
      } catch (error) {
        const reason = ["mood-input-invalid", "mood-identity-unverified", "mood-rate-limited",
          "mood-capacity-unavailable", "mood-store-unavailable", "mood-busy",
          "mood-proof-unavailable", "mood-placement-unavailable"].includes(error?.message) ? error.message : "mood-unavailable";
        return { resultType: "failure", textResultForLlm: `Maestro mood refused or uncertain (${reason}). No queue, fallback or retry.` };
      }
    },
  };
}
