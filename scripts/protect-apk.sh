#!/usr/bin/env bash
set -euo pipefail

INPUT_APK="${INPUT_APK:-Miku Moe.apk}"
WORK_DIR="work"
OUTPUT_DIR="output"
DEX2C_DIR="tools/dex2c"
FINAL_APK="$OUTPUT_DIR/miku-protected-universal-unsigned.apk"
UNSIGNED_APK="$WORK_DIR/miku-protected-unsigned.apk"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
MAX_DEX2C_ATTEMPTS="${MAX_DEX2C_ATTEMPTS:-5}"

if [ ! -f "$INPUT_APK" ]; then
FOUND_APK="$(find . -maxdepth 2 -type f -iname "*.apk" | sort | head -n 1 || true)"
if [ -n "$FOUND_APK" ]; then
INPUT_APK="${FOUND_APK#./}"
fi
fi

if [ ! -f "$INPUT_APK" ]; then
echo "APK tidak ditemukan: $INPUT_APK"
find . -maxdepth 2 -type f -print || true
exit 1
fi

echo "Menggunakan APK input: $INPUT_APK"

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR" tools

cp "$INPUT_APK" "$WORK_DIR/input.apk"

if [ ! -f "$DEX2C_DIR/dcc.py" ]; then
rm -rf "$DEX2C_DIR"
git clone --depth 1 https://github.com/codehasan/dex2c.git "$DEX2C_DIR"
fi

cd "$DEX2C_DIR"

python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

python3 - <<'PY'
from pathlib import Path

path = Path("dcc.py")
text = path.read_text(encoding="utf-8")
marker = "def build_project(project_dir):\n"
helper = r'''
def patch_dex2c_generated_cpp(project_dir):
    import re
    from pathlib import Path
    fields = {
        "jboolean": "z",
        "jbyte": "b",
        "jchar": "c",
        "jshort": "s",
        "jint": "i",
        "jlong": "j",
        "jfloat": "f",
        "jdouble": "d"
    }
    root = Path(project_dir)
    total = 0
    for cpp in root.rglob("*.cpp"):
        try:
            data = cpp.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            data = cpp.read_text(errors="ignore")
        declarations = {}
        for typ, name in re.findall(r"\b(jboolean|jbyte|jchar|jshort|jint|jlong|jfloat|jdouble)\s+([A-Za-z_]\w*)\b", data):
            declarations[name] = fields[typ]
        changed = 0
        def fix_jvalue(match):
            nonlocal changed
            old_field = match.group(1)
            name = match.group(2)
            new_field = declarations.get(name)
            if new_field and old_field != new_field:
                changed += 1
                return "{." + new_field + " = " + name + "}"
            return match.group(0)
        patched = re.sub(r"\{\s*\.\s*([A-Za-z])\s*=\s*([A-Za-z_]\w*)\s*\}", fix_jvalue, data)
        if patched != data:
            cpp.write_text(patched, encoding="utf-8")
            total += changed
    if total:
        print("[INFO    ] dcc: Patched", total, "jvalue initializer field(s)")
'''

if marker not in text:
    raise SystemExit("build_project tidak ditemukan di dcc.py")

if "def patch_dex2c_generated_cpp(project_dir):" not in text:
    text = text.replace(marker, helper + "\n" + marker, 1)

patched_marker = "def build_project(project_dir):\n    patch_dex2c_generated_cpp(project_dir)\n"
if patched_marker not in text:
    text = text.replace(marker, patched_marker, 1)

path.write_text(text, encoding="utf-8")
PY

mkdir -p tools

if [ ! -s "tools/apktool.jar" ]; then
if ! curl -L --fail -o "tools/apktool.jar" "https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"; then
curl -L --fail -o "tools/apktool.jar" "https://github.com/iBotPeaches/Apktool/releases/download/v2.11.1/apktool_2.11.1.jar"
fi
fi

test -s "tools/apktool.jar"
java -jar "tools/apktool.jar" --version

cd ../..

NDK_DIR="${ANDROID_NDK_HOME:-}"

if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
for CANDIDATE in "$ANDROID_HOME/ndk/25.2.9519653" "$ANDROID_SDK_ROOT/ndk/25.2.9519653" "/usr/local/lib/android/sdk/ndk/25.2.9519653"; do
if [ -d "$CANDIDATE" ]; then
NDK_DIR="$CANDIDATE"
break
fi
done
fi

if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
for BASE in "$ANDROID_HOME/ndk" "$ANDROID_SDK_ROOT/ndk" "/usr/local/lib/android/sdk/ndk"; do
if [ -d "$BASE" ]; then
NDK_DIR="$(find "$BASE" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1 || true)"
if [ -n "$NDK_DIR" ] && [ -d "$NDK_DIR" ]; then
break
fi
fi
done
fi

if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
echo "ANDROID_NDK_HOME tidak ditemukan"
exit 1
fi

export ANDROID_HOME
export ANDROID_SDK_ROOT
export ANDROID_NDK_HOME="$NDK_DIR"

python3 - <<PY
import json
from pathlib import Path

ndk = "$NDK_DIR"
cfg = {
"apktool": "tools/apktool.jar",
"ndk_dir": ndk,
"signature": {
"keystore_path": "keystore/debug.keystore",
"alias": "androiddebugkey",
"keystore_pass": "android",
"store_pass": "android",
"v1_enabled": True,
"v2_enabled": True,
"v3_enabled": True
},
"ollvm": {
"enable": False,
"flags": "-fvisibility=hidden"
}
}

cfg_path = Path("tools/dex2c/dcc.cfg")
cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
json.loads(cfg_path.read_text(encoding="utf-8"))
PY

cat > "$DEX2C_DIR/project/jni/Application.mk" <<'EOF_APP'
APP_STL := c++_static
APP_CPPFLAGS += -fvisibility=hidden
APP_PLATFORM := android-19
APP_ABI := armeabi-v7a arm64-v8a x86 x86_64
APP_SHORT_COMMANDS := true
EOF_APP

cat > "$DEX2C_DIR/project/jni/Android.mk" <<'EOF_MK'
LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := mikumoe
LOCAL_LDLIBS := -llog
LOCAL_LDFLAGS += "-Wl,-z,max-page-size=16384"
SOURCES := $(wildcard $(LOCAL_PATH)/nc/*.cpp)
LOCAL_C_INCLUDES := $(LOCAL_PATH)/nc
LOCAL_SRC_FILES := $(SOURCES:$(LOCAL_PATH)/%=%)
LOCAL_SHORT_COMMANDS := true
include $(BUILD_SHARED_LIBRARY)
EOF_MK

ZIPALIGN_PATH=""

for BASE in "$ANDROID_HOME/build-tools" "$ANDROID_SDK_ROOT/build-tools" "/usr/local/lib/android/sdk/build-tools"; do
if [ -d "$BASE" ]; then
ZIPALIGN_PATH="$(find "$BASE" -type f -name zipalign 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "$ZIPALIGN_PATH" ]; then
break
fi
fi
done

if [ -z "$ZIPALIGN_PATH" ]; then
echo "zipalign tidak ditemukan"
for BASE in "$ANDROID_HOME/build-tools" "$ANDROID_SDK_ROOT/build-tools" "/usr/local/lib/android/sdk/build-tools"; do
if [ -d "$BASE" ]; then
find "$BASE" -maxdepth 3 -type f -print || true
fi
done
exit 1
fi

export PATH="$(dirname "$ZIPALIGN_PATH"):$PATH"

command -v zipalign
ZIPALIGN_HELP="$(zipalign 2>&1 || true)"
printf '%s\n' "$ZIPALIGN_HELP" | head -n 30 || true

cp "$WORK_DIR/input.apk" "$DEX2C_DIR/input.apk"

EXCLUDE_FILE="$WORK_DIR/dex2c-method-excludes.txt"
: > "$EXCLUDE_FILE"

add_filter_file() {
{
echo "miku/moe/app/.*;.*"
echo "!miku/moe/app/R.*;.*"
echo "!miku/moe/app/BuildConfig;.*"
echo "!miku/moe/app/F6;G.*"
if [ -s "$EXCLUDE_FILE" ]; then
cat "$EXCLUDE_FILE"
fi
} > "$DEX2C_DIR/filter.txt"
}

parse_failed_native_methods() {
python3 - "$WORK_DIR/dex2c-attempt.log" "$EXCLUDE_FILE" <<'PY'
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
text = log_path.read_text(errors="ignore") if log_path.exists() else ""
found = []
for filename in sorted(set(re.findall(r"jni/nc/(Java_miku_moe_app_[^:\s]+\.cpp):\d+:\d+: error:", text))):
    stem = filename[:-4]
    prefix = "Java_miku_moe_app_"
    if not stem.startswith(prefix):
        continue
    body = stem[len(prefix):]
    if "__" in body:
        before_signature = body.rsplit("__", 1)[0]
    else:
        before_signature = body
    if "_" not in before_signature:
        continue
    cls, method = before_signature.rsplit("_", 1)
    if not cls or not method:
        continue
    if method.startswith("0003c") or method.startswith("0003e"):
        rule = f"!miku/moe/app/{cls};.*"
    else:
        rule = f"!miku/moe/app/{cls};{method}.*"
    found.append(rule)
existing = set()
if out_path.exists():
    existing = {line.strip() for line in out_path.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()}
new_rules = [rule for rule in found if rule not in existing]
if new_rules:
    with out_path.open("a", encoding="utf-8") as f:
        for rule in new_rules:
            f.write(rule + "\n")
    print("Menambahkan exclude method dex2c rusak:")
    for rule in new_rules:
        print(rule)
else:
    print("Tidak ada exclude method baru dari error C++")
PY
}

SUCCESS="0"

for ATTEMPT in $(seq 1 "$MAX_DEX2C_ATTEMPTS"); do
add_filter_file
echo "Filter dex2c attempt $ATTEMPT:"
cat "$DEX2C_DIR/filter.txt"
cd "$DEX2C_DIR"
rm -f output.apk
rm -rf .tmp
python3 -m json.tool dcc.cfg >/dev/null
java -jar "tools/apktool.jar" --version
cat project/jni/Application.mk
cat project/jni/Android.mk
set +e
python3 dcc.py -a input.apk -o output.apk --disable-signing 2>&1 | tee "../../$WORK_DIR/dex2c-attempt.log"
DCC_STATUS="${PIPESTATUS[0]}"
set -e
cd ../..
cat "$WORK_DIR/dex2c-attempt.log" >> "$WORK_DIR/dex2c.log"
if [ "$DCC_STATUS" -eq 0 ] && [ -f "$DEX2C_DIR/output.apk" ]; then
SUCCESS="1"
break
fi
parse_failed_native_methods
if [ "$ATTEMPT" -eq "$MAX_DEX2C_ATTEMPTS" ]; then
tail -n 240 "$WORK_DIR/dex2c-attempt.log" || true
exit 1
fi
done

if [ "$SUCCESS" != "1" ]; then
echo "dex2c gagal membuat output.apk"
exit 1
fi

cp "$DEX2C_DIR/output.apk" "$UNSIGNED_APK"

if printf '%s\n' "$ZIPALIGN_HELP" | grep -q -- "-P <pagesize_kb>"; then
zipalign -P 16 -f 4 "$UNSIGNED_APK" "$FINAL_APK"
else
zipalign -p -f 4 "$UNSIGNED_APK" "$FINAL_APK"
fi

test -f "$FINAL_APK"
ls -lh "$FINAL_APK"

if ! unzip -l "$FINAL_APK" | grep "libmikumoe.so"; then
unzip -l "$FINAL_APK" | grep ".so" || true
exit 1
fi

PROTECTED_SYMBOL_COUNT="$(unzip -p "$FINAL_APK" 'lib/*/libmikumoe.so' 2>/dev/null | strings | grep -c 'Java_miku_moe_app_' || true)"
echo "Jumlah symbol native miku.moe.app: $PROTECTED_SYMBOL_COUNT"

if [ "${PROTECTED_SYMBOL_COUNT:-0}" -le 0 ]; then
echo "Tidak ada symbol native miku.moe.app di APK final"
exit 1
fi

if [ -s "$EXCLUDE_FILE" ]; then
echo "Method yang dilewati karena dex2c generate C++ rusak:"
cat "$EXCLUDE_FILE"
fi
