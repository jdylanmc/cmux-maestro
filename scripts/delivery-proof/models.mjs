export const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}$/;
export const CONTEXT_TIERS = ["default", "long_context"];
const REASONING_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
export const PREFERENCES = ["model", "contextTier", "reasoningEffort"];
const OPTION = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MAX_OPTIONS = 4096;
const OPTION_SCAN = 256;

function check(condition, reason) {
  if (!condition) throw new Error(reason);
}

export function modelObservation(snapshot) {
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot) ||
      (snapshot.modelId !== undefined &&
        (typeof snapshot.modelId !== "string" || !MODEL_ID.test(snapshot.modelId))) ||
      (snapshot.contextTier !== undefined && !CONTEXT_TIERS.includes(snapshot.contextTier)) ||
      (snapshot.reasoningEffort !== undefined &&
        (typeof snapshot.reasoningEffort !== "string" ||
          !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(snapshot.reasoningEffort)))) {
    return { status: "unavailable", reason: "model-response-invalid" };
  }
  if (snapshot.modelId === undefined) {
    return { status: "unavailable", reason: "model-not-reported" };
  }
  return {
    status: "observed", source: "session-model-current", observedAt: new Date().toISOString(),
    model: snapshot.modelId,
    ...(snapshot.contextTier === undefined ? {} : { contextTier: snapshot.contextTier }),
    ...(snapshot.reasoningEffort === undefined ? {} : { reasoningEffort: snapshot.reasoningEffort }),
  };
}

export function validatePreferences(assignment) {
  for (const key of PREFERENCES) {
    if (!(key in assignment)) continue;
    check(typeof assignment[key] === "string" &&
      (key === "model" ? MODEL_ID : OPTION).test(assignment[key]), `spawn-input-invalid: ${key}`);
  }
}

export function modelCapabilities(response) {
  check(response && Array.isArray(response.list), "model-list-invalid: list");
  check(response.list.length <= 128, "model-list-invalid: model-count");
  const ids = new Set();
  function options(value, supported, field) {
    if (!Array.isArray(value)) return [];
    check(value.length <= MAX_OPTIONS,
      `model-list-invalid: ${field} (type=array,length=${value.length},max=${MAX_OPTIONS})`);
    return [...new Set(value.slice(0, OPTION_SCAN).filter(item =>
      typeof item === "string" && OPTION.test(item) && supported.includes(item)))];
  }
  return response.list.map(model => {
    check(model && typeof model === "object" && !Array.isArray(model) &&
      typeof model.id === "string" && MODEL_ID.test(model.id), "model-list-invalid: model-id");
    check(!ids.has(model.id), "model-list-invalid: duplicate-id");
    ids.add(model.id);
    const contextTiers = options(model.supportedContextTiers, CONTEXT_TIERS, "context-options");
    if (!contextTiers.includes("default")) contextTiers.unshift("default");
    // session.model.list returns raw CAPI metadata; BYOK entries may use the SDK Model shape.
    for (const longContext of [model.billing?.tokenPrices?.longContext,
      model.billing?.token_prices?.long_context]) {
      if (longContext === undefined) continue;
      check(longContext !== null && typeof longContext === "object" && !Array.isArray(longContext),
        "model-list-invalid: long-context");
      if (!contextTiers.includes("long_context")) contextTiers.push("long_context");
    }
    const rawEfforts = model.supportedReasoningEfforts;
    const capiEfforts = model.capabilities?.supports?.reasoning_effort;
    const reasoningEfforts = options(rawEfforts, REASONING_EFFORTS, "effort-options");
    const capi = options(capiEfforts, REASONING_EFFORTS, "capi-effort-options");
    // Conflicting advertisements cannot widen what either representation supports.
    const efforts = !Array.isArray(rawEfforts) ? capi : !Array.isArray(capiEfforts)
      ? reasoningEfforts : reasoningEfforts.filter(item => capi.includes(item));
    const result = { id: model.id, contextTiers, reasoningEfforts: efforts };
    if (efforts.includes(model.defaultReasoningEffort)) result.defaultReasoningEffort = model.defaultReasoningEffort;
    return result;
  });
}
