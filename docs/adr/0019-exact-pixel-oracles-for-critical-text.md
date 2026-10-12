# Exact pixel oracles for critical text

Footer model text, copy controls, inspector model lines, and unavailable-state text are validated against native 2x pixel references with no tolerance. OCR is allowed only for two natural-language warnings. Renders are synthetic, offscreen, and local; they are not live CMUX captures or VoiceOver proof.

Why: wrong, hidden, clipped, substituted, or suffixed text looks right to OCR and tolerant diffs.

Rejected: resampling, OCR aliases, averaged ink scores, pixel tolerance.

Consequence: any layout change near those regions needs its reference updated, and the tests are brittle on purpose.
