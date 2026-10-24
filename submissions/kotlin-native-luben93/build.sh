#!/usr/bin/env bash
# Builds the Kotlin/Native server, build/bin/linuxX64/releaseExecutable/conduit.kexe, as a normal user. Idempotent.
# Gradle (pinned, checksummed wrapper) runs on the JDK from install.sh and downloads the Kotlin/Native toolchain
# (compiler + LLVM) itself; the first build takes several minutes. cinterop compiles native/ (the vendored Openwall
# bcrypt core) into the binary with that toolchain's clang, so no system C compiler is needed.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
./gradlew --no-daemon -q linkReleaseExecutableLinuxX64
ls -l build/bin/linuxX64/releaseExecutable/conduit.kexe
