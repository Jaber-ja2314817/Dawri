#!/bin/zsh
# The no-credit search, from the shell. It is the same search, with the same allowlist, as
# ios/DawriCore/Tests/DawriCoreTests/Remote/NoCreditSourceTests.swift.
#
# Every line under the app's folders that names a Hugging Face host, a model provider or the
# speech upload path is printed as file:line with its verdict. Any hit outside the allowlist
# fails. The session type may be named only in the Clinic server client.
#
# It reads files only. It reads no .env, starts nothing and sends nothing.
#
# No-credit allowlist: this file is a banned list, so it names every banned word on purpose.
#
# Usage: ios/Tools/no-credit-check.sh        exit 0 clean, 1 on any hit outside the allowlist

emulate -L zsh
setopt pipe_fail no_unset

ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 2

scanned=(
  ios/Dawri ios/DawriLive ios/DawriCore/Sources ios/DawriCore/Tests
  ios/DawriUITests ios/Tools ios/Config
)
banned=(
  hf.space huggingface hf.co novita featherless ovhcloud together.ai
  openai anthropic api-inference router.huggingface whisper /api/asr
)
# Written in two parts so this file does not itself name the session type.
session_type='URL''Session'
corpus_terms=(featherless novita openai whisper)

# The banned words on one lowered line, space separated.
terms_in() {
  local low=${(L)1} term found=()
  for term in $banned; do
    [[ $low == *"$term"* ]] && found+=$term
  done
  print -r -- "${found[*]}"
}

# True when every word in $1 is one of the corpus words.
only_corpus_terms() {
  local term
  for term in ${=1}; do
    (( ${corpus_terms[(Ie)$term]} )) || return 1
  done
  return 0
}

# The reason a banned hit is allowed, or nothing. Keep in step with NoCreditSourceTests.swift.
allowed_reason() {
  local file=$1 text=$2 terms=$3
  case $file in
    ios/DawriCore/Sources/DawriCore/Patient/ServerAddress.swift)
      print "the address guard, which refuses these hosts"; return ;;
    ios/DawriCore/Tests/DawriCoreTests/Patient/ServerAddressTests.swift)
      print "the address guard's tests"; return ;;
    ios/DawriCore/Tests/DawriCoreTests/Remote/CreditGuardTests.swift)
      print "the Remote guard tests"; return ;;
    ios/DawriCore/Tests/DawriCoreTests/Remote/NoCreditSourceTests.swift)
      print "the banned list"; return ;;
    ios/Tools/no-credit-check.sh)
      print "this banned list"; return ;;
    ios/DawriUITests/ServerModeTests.swift)
      print "the Clinic server UI tests and their refusal cases"; return ;;
    ios/DawriCore/Tests/DawriCoreTests/Local/JourneyTests.swift)
      [[ $text == *'for banned in ['* ]] && { print "a banned list over the journey's text"; return; } ;;
    ios/DawriCore/Tests/DawriCoreTests/DriftTests.swift)
      [[ $text == *'contains("/api/asr\"")'* ]] && { print "a guard test: no Swift source names the speech path"; return; } ;;
    ios/Tools/export/harvest_plugin.py)
      [[ $text == *'NEVER_NAMED = re.compile('* ]] && { print "the harvest's banned regex"; return; } ;;
    ios/Tools/shots/account.tsv)
      [[ $text == *settings-refused-host* ]] && { print "the shot of the refused-host message"; return; } ;;
    ios/DawriUITests/AccountScreenTests.swift)
      [[ $text == *'app.typeText("https://User@Dawri.HF.Space.:443")'* ]] && { print "the refused-host UI test"; return; }
      [[ $text == *'"-demoAddress", "https://dawri.hf.space"'* ]] && { print "the refused-host UI test, plain Space address"; return; } ;;
    ios/DawriCore/Tests/DawriCoreTests/Patient/ChatModelTests.swift)
      [[ $text == *'calls /api/asr, so they cannot happen.'* ]] && { print "a comment: the speech-upload cases cannot happen"; return; } ;;
    ios/DawriCore/Tests/DawriCoreTests/Fixtures/goldens/*|ios/Tools/export/harvested-inputs.json)
      only_corpus_terms "$terms" && { print "rule-input text harvested from backend tests ($terms)"; return; } ;;
  esac
}

session_reason() {
  local file=$1 text=$2
  case $file in
    ios/DawriCore/Sources/DawriCore/Remote/*) print "the Clinic server client"; return ;;
    ios/DawriUITests/ServerModeTests.swift) print "the live server UI tests"; return ;;
  esac
}

failed=0
count=0

grep_args=()
for term in $banned; do grep_args+=(-e "$term"); done

while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  text=${rest#*:}
  terms=$(terms_in "$text")
  reason=$(allowed_reason "$file" "$text" "$terms")
  count=$((count + 1))
  if [[ -n $reason ]]; then
    print -r -- "$file:$line  allowed  [$terms]  $reason"
  else
    print -r -- "$file:$line  FAIL  [$terms]  ${text[1,160]}"
    failed=1
  fi
done < <(/usr/bin/grep -rniIF "${grep_args[@]}" -- $scanned)

while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  text=${rest#*:}
  reason=$(session_reason "$file" "$text")
  count=$((count + 1))
  if [[ -n $reason ]]; then
    print -r -- "$file:$line  allowed  [$session_type]  $reason"
  else
    print -r -- "$file:$line  FAIL  [$session_type]  ${text[1,160]}"
    failed=1
  fi
done < <(/usr/bin/grep -rnIF -e "$session_type" -- $scanned)

# The app may reach only the local network over plain http, and the extension nothing extra.
ats=$(/usr/bin/plutil -extract NSAppTransportSecurity json -o - ios/Config/Dawri-Info.plist 2>/dev/null)
if [[ $ats == '{"NSAllowsLocalNetworking":true}' ]]; then
  print -r -- "ios/Config/Dawri-Info.plist  allowed  NSAppTransportSecurity is exactly $ats"
else
  print -r -- "ios/Config/Dawri-Info.plist  FAIL  NSAppTransportSecurity is ${ats:-missing}"
  failed=1
fi
usage=$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw -o - ios/Config/Dawri-Info.plist 2>/dev/null)
if [[ -z ${usage// /} ]]; then
  print -r -- "ios/Config/Dawri-Info.plist  FAIL  NSLocalNetworkUsageDescription is missing"
  failed=1
fi
if /usr/bin/plutil -extract NSAppTransportSecurity json -o - ios/Config/DawriLive-Info.plist >/dev/null 2>&1; then
  print -r -- "ios/Config/DawriLive-Info.plist  FAIL  the extension has an ATS key"
  failed=1
fi

if (( failed )); then
  print -r -- "no-credit-check: FAILED ($count hits searched)"
  exit 1
fi
print -r -- "no-credit-check: clean ($count hits, every one allowed)"
exit 0
