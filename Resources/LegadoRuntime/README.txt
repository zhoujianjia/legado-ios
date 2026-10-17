This directory preserves the staged JVM payload's directory structure in the app bundle.

Run scripts/legado-ios/stage-runtime.py after building the locked JVM core and
OpenJDK Mobile Zero. Generated Java modules and JARs are intentionally ignored by Git.
The source-only checkout exposes diagnostics and reports missing artifacts explicitly.
