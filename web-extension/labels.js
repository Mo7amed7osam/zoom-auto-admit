// Button labels the content script looks for, per Zoom UI language.
// Matching is exact (after whitespace/case normalization) so unrelated buttons
// that merely contain the word "admit" are never pressed.
const ZAA_LABELS = {
  admitAll: [
    "admit all",
    "admit all participants",
    "قبول الكل",
    "السماح للجميع",
    "admitir a todos",
    "admettre tous",
    "alle zulassen"
  ],
  admit: [
    "admit",
    "قبول",
    "السماح",
    "admitir",
    "admettre",
    "zulassen"
  ],
  // Labels that must never be pressed, even if a match above also fits.
  blocked: [
    "deny",
    "remove",
    "deny entry",
    "remove from meeting",
    "رفض",
    "إزالة"
  ]
};
