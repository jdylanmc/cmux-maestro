export const notificationSpec = {
  name: "maestro_notify",
  description: "Notify the human through macOS from your verified session. Use for a blocker, decision or completed task, not progress spam. Message is shortened to 140 characters. Urgent adds sound, not Focus bypass. Muted/rate-limited refusals are explicit; never automatically retry.",
  parameters: {
    type: "object", properties: {
      message: { type: "string", maxLength: 8192 },
      priority: { type: "string", enum: ["normal", "urgent"] },
    }, required: ["message"], additionalProperties: false,
  },
};

export function notificationTool({ own, ownAddress, session, currentBinding, notify, controller }) {
  return {
    ...notificationSpec,
    handler: async (args, invocation) => {
      try {
        if (session()?.sessionId !== own.sessionId || invocation?.sessionId !== own.sessionId ||
            !args || typeof args !== "object" || Array.isArray(args) ||
            Object.keys(args).some(key => !["message", "priority"].includes(key)) ||
            typeof args.message !== "string" || args.message.length > 8192 || !args.message.trim() ||
            (args.priority !== undefined && !["normal", "urgent"].includes(args.priority))) {
          throw new Error("notification-input-invalid");
        }
        await currentBinding();
        return JSON.stringify(await notify({
          identity: { nodeId: own.nodeId, ...ownAddress, capability: own.capability },
          message: args.message, priority: args.priority ?? "normal",
        }, controller));
      } catch (error) {
        const reason = ["muted", "rate-limited", "notifications-not-authorized", "notification-input-invalid",
          "notification-identity-unverified", "notification-settings-unavailable",
          "notification-capacity-unavailable"].includes(error.message) ? error.message : "notification-unavailable";
        return { resultType: "failure", textResultForLlm: `${reason}. No retry was made.` };
      }
    },
  };
}
