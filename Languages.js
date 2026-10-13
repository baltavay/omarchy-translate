// Language table for the translate overlay.
//
// Codes are the ones Google's endpoints speak ("auto", "zh-CN", "pt"); the
// fetch script normalizes the few legacy aliases (iw, nb, bare zh) itself.
// English name first for searching, native name so the picker stays usable
// when the reader can't read English.
.pragma library

var languages = [
  { code: "auto",  name: "Detect language", native: "Auto" },
  { code: "en",    name: "English",         native: "English" },
  { code: "ru",    name: "Russian",         native: "Русский" },
  { code: "ky",    name: "Kyrgyz",          native: "Кыргызча" },
  { code: "kk",    name: "Kazakh",          native: "Қазақша" },
  { code: "uz",    name: "Uzbek",           native: "Oʻzbekcha" },
  { code: "tg",    name: "Tajik",           native: "Тоҷикӣ" },
  { code: "tk",    name: "Turkmen",         native: "Türkmençe" },
  { code: "az",    name: "Azerbaijani",     native: "Azərbaycan" },
  { code: "tr",    name: "Turkish",         native: "Türkçe" },
  { code: "uk",    name: "Ukrainian",       native: "Українська" },
  { code: "be",    name: "Belarusian",      native: "Беларуская" },
  { code: "hy",    name: "Armenian",        native: "Հայերեն" },
  { code: "ka",    name: "Georgian",        native: "ქართული" },
  { code: "he",    name: "Hebrew",          native: "עברית" },
  { code: "ar",    name: "Arabic",          native: "العربية" },
  { code: "fa",    name: "Persian",         native: "فارسی" },
  { code: "ur",    name: "Urdu",            native: "اردو" },
  { code: "hi",    name: "Hindi",           native: "हिन्दी" },
  { code: "bn",    name: "Bengali",         native: "বাংলা" },
  { code: "ta",    name: "Tamil",           native: "தமிழ்" },
  { code: "te",    name: "Telugu",          native: "తెలుగు" },
  { code: "ne",    name: "Nepali",          native: "नेपाली" },
  { code: "si",    name: "Sinhala",         native: "සිංහල" },
  { code: "mn",    name: "Mongolian",       native: "Монгол" },
  { code: "zh-CN", name: "Chinese (simplified)", native: "简体中文" },
  { code: "zh-TW", name: "Chinese (traditional)", native: "繁體中文" },
  { code: "ja",    name: "Japanese",        native: "日本語" },
  { code: "ko",    name: "Korean",          native: "한국어" },
  { code: "th",    name: "Thai",            native: "ไทย" },
  { code: "vi",    name: "Vietnamese",      native: "Tiếng Việt" },
  { code: "id",    name: "Indonesian",      native: "Bahasa Indonesia" },
  { code: "ms",    name: "Malay",           native: "Bahasa Melayu" },
  { code: "tl",    name: "Filipino",        native: "Filipino" },
  { code: "de",    name: "German",          native: "Deutsch" },
  { code: "fr",    name: "French",          native: "Français" },
  { code: "es",    name: "Spanish",         native: "Español" },
  { code: "it",    name: "Italian",         native: "Italiano" },
  { code: "pt",    name: "Portuguese",      native: "Português" },
  { code: "nl",    name: "Dutch",           native: "Nederlands" },
  { code: "sv",    name: "Swedish",         native: "Svenska" },
  { code: "no",    name: "Norwegian",       native: "Norsk" },
  { code: "da",    name: "Danish",          native: "Dansk" },
  { code: "fi",    name: "Finnish",         native: "Suomi" },
  { code: "is",    name: "Icelandic",       native: "Íslenska" },
  { code: "pl",    name: "Polish",          native: "Polski" },
  { code: "cs",    name: "Czech",           native: "Čeština" },
  { code: "sk",    name: "Slovak",          native: "Slovenčina" },
  { code: "hu",    name: "Hungarian",       native: "Magyar" },
  { code: "ro",    name: "Romanian",        native: "Română" },
  { code: "bg",    name: "Bulgarian",       native: "Български" },
  { code: "el",    name: "Greek",           native: "Ελληνικά" },
  { code: "sr",    name: "Serbian",         native: "Српски" },
  { code: "hr",    name: "Croatian",        native: "Hrvatski" },
  { code: "sl",    name: "Slovenian",       native: "Slovenščina" },
  { code: "bs",    name: "Bosnian",         native: "Bosanski" },
  { code: "mk",    name: "Macedonian",      native: "Македонски" },
  { code: "sq",    name: "Albanian",        native: "Shqip" },
  { code: "lt",    name: "Lithuanian",      native: "Lietuvių" },
  { code: "lv",    name: "Latvian",         native: "Latviešu" },
  { code: "et",    name: "Estonian",        native: "Eesti" },
  { code: "sw",    name: "Swahili",         native: "Kiswahili" },
  { code: "eo",    name: "Esperanto",       native: "Esperanto" }
];

function byCode(code) {
  var want = String(code || "");
  for (var i = 0; i < languages.length; i++)
    if (languages[i].code === want) return languages[i];
  return null;
}

function exists(code) { return byCode(code) !== null; }

// "EN", "ZH-CN" — what fits on a chip.
function chip(code) { return String(code || "").toUpperCase(); }

// "English (English)" feels silly; the native name is the interesting one.
function subtitle(lang) {
  if (!lang) return "";
  return lang.native === lang.name ? lang.code : lang.native;
}

function search(query) {
  var q = String(query || "").trim().toLowerCase();
  if (q === "") return languages.slice();
  var out = [];
  for (var i = 0; i < languages.length; i++) {
    var lang = languages[i];
    if (lang.code.toLowerCase().indexOf(q) === 0
        || lang.name.toLowerCase().indexOf(q) >= 0
        || lang.native.toLowerCase().indexOf(q) >= 0)
      out.push(lang);
  }
  // Code prefixes first, so typing "e" lands on English before French.
  out.sort(function(a, b) {
    return (a.code.toLowerCase().indexOf(q) === 0 ? 0 : 1) - (b.code.toLowerCase().indexOf(q) === 0 ? 0 : 1);
  });
  return out;
}
