#!/bin/bash
# .claude/hooks/pre-commit.sh
# Runs on every Bash PreToolUse in Claude Code.
# Only acts when the command is a git commit.
#
# Technology-agnostic: detects the stacks present by their marker files
# and runs tests + lint with whichever tools are installed.
# For uncovered stacks or custom commands, see "Customization" in the README:
#   - Environment variables: HOOK_TEST_CMD, HOOK_LINT_CMD, HOOK_SKIP_STACKS
#   - Optional script: .claude/hooks/project-checks.sh (exit != 0 = failure)

INPUT=$(cat)

# Extract the command from the JSON (jq if available; otherwise sed fallback)
if command -v jq &> /dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
  COMMAND=$(echo "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -1)
fi
if ! echo "$COMMAND" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit'; then
  exit 0
fi

# Run from the repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 0

echo ""
echo "======================================="
echo "  Checks pre-commit"
echo "======================================="

ERRORS=0
DETECTED=0

has_file() { # has_file pattern...  (supports globs)
  local f
  for f in "$@"; do compgen -G "$f" > /dev/null && return 0; done
  return 1
}

stack_enabled() { [[ " $HOOK_SKIP_STACKS " != *" $1 "* ]]; }

# run_check "<label>" <command...>
run_check() {
  local label="$1"; shift
  echo "  $label..."
  if "$@" 2>&1; then
    echo "  ✓ $label OK"
  else
    echo "  ✗ $label failed"
    ERRORS=$((ERRORS + 1))
  fi
}

# run_sh "<label>" "<command as string>"  (for user commands)
run_sh() { run_check "$1" bash -c "$2"; }

begin_stack() { DETECTED=$((DETECTED + 1)); echo ""; echo "▶ Stack detectado: $1"; }

# ─── User-defined commands (replace autodetection) ───
if [ -n "$HOOK_TEST_CMD" ] || [ -n "$HOOK_LINT_CMD" ]; then
  begin_stack "personalizado"
  [ -n "$HOOK_TEST_CMD" ] && run_sh "Tests" "$HOOK_TEST_CMD"
  [ -n "$HOOK_LINT_CMD" ] && run_sh "Lint" "$HOOK_LINT_CMD"
else
  # ─── Python ─────────────────────────────────────────────────
  if stack_enabled python && has_file requirements*.txt setup.py setup.cfg pyproject.toml Pipfile; then
    begin_stack "Python"
    if command -v pytest &> /dev/null && has_file tests test "test_*.py" "*_test.py"; then
      run_check "Tests (pytest)" pytest -q --tb=short
    fi
    if command -v ruff &> /dev/null; then
      run_check "Lint (ruff)" ruff check .
    elif command -v flake8 &> /dev/null; then
      run_check "Lint (flake8)" flake8 . --max-line-length=100 --exclude=venv,.venv,migrations
    fi
  fi

  # ─── Node.js / TypeScript ───────────────────────────────────
  if stack_enabled node && [ -f package.json ]; then
    begin_stack "Node.js"
    PM=npm
    [ -f pnpm-lock.yaml ] && PM=pnpm
    [ -f yarn.lock ] && PM=yarn
    [ -f bun.lockb ] || [ -f bun.lock ] && PM=bun
    if command -v "$PM" &> /dev/null; then
      # Respects the project scripts: works for Express, React, Angular, etc.
      if grep -q '"test"[[:space:]]*:' package.json && ! grep -q 'no test specified' package.json; then
        run_check "Tests ($PM test)" "$PM" run test
      fi
      if grep -q '"lint"[[:space:]]*:' package.json; then
        run_check "Lint ($PM run lint)" "$PM" run lint
      fi
      if [ -f tsconfig.json ] && [ -x node_modules/.bin/tsc ]; then
        run_check "Tipos (tsc)" node_modules/.bin/tsc --noEmit
      fi
    fi
  fi

  # ─── Go ─────────────────────────────────────────────────────
  if stack_enabled go && [ -f go.mod ] && command -v go &> /dev/null; then
    begin_stack "Go"
    run_check "Tests (go test)" go test ./...
    run_check "Analysis (go vet)" go vet ./...
  fi

  # ─── Rust ───────────────────────────────────────────────────
  if stack_enabled rust && [ -f Cargo.toml ] && command -v cargo &> /dev/null; then
    begin_stack "Rust"
    run_check "Tests (cargo test)" cargo test --quiet
    run_check "Lint (cargo clippy)" cargo clippy --quiet -- -D warnings
  fi

  # ─── Java / Kotlin ──────────────────────────────────────────
  if stack_enabled java; then
    if [ -f pom.xml ] && command -v mvn &> /dev/null; then
      begin_stack "Java (Maven)"
      run_check "Tests (mvn test)" mvn -q test
    elif has_file build.gradle build.gradle.kts; then
      GRADLE=gradle
      [ -x ./gradlew ] && GRADLE=./gradlew
      if command -v "$GRADLE" &> /dev/null || [ -x ./gradlew ]; then
        begin_stack "Java/Kotlin (Gradle)"
        run_check "Tests (gradle test)" "$GRADLE" -q test
      fi
    fi
  fi

  # ─── .NET ───────────────────────────────────────────────────
  if stack_enabled dotnet && has_file "*.sln" "*.csproj" "*.fsproj" && command -v dotnet &> /dev/null; then
    begin_stack ".NET"
    run_check "Tests (dotnet test)" dotnet test --nologo -v q
  fi

  # ─── Ruby ───────────────────────────────────────────────────
  if stack_enabled ruby && [ -f Gemfile ] && command -v bundle &> /dev/null; then
    begin_stack "Ruby"
    if [ -d spec ]; then
      run_check "Tests (rspec)" bundle exec rspec
    elif [ -d test ]; then
      run_check "Tests (rake test)" bundle exec rake test
    fi
    [ -f .rubocop.yml ] && run_check "Lint (rubocop)" bundle exec rubocop
  fi

  # ─── PHP ────────────────────────────────────────────────────
  if stack_enabled php && [ -f composer.json ]; then
    begin_stack "PHP"
    if [ -x vendor/bin/phpunit ]; then
      run_check "Tests (phpunit)" vendor/bin/phpunit
    fi
  fi
fi

# ─── Project's own script (optional) ───────────────────
if [ -f .claude/hooks/project-checks.sh ]; then
  begin_stack "project checks"
  run_check "project-checks.sh" bash .claude/hooks/project-checks.sh
fi

if [ "$DETECTED" -eq 0 ]; then
  echo ""
  echo "▶ No recognized stack — skipping tests and lint."
  echo "  (Define HOOK_TEST_CMD / HOOK_LINT_CMD o .claude/hooks/project-checks.sh)"
fi

# ─── Hardcoded credentials (any language) ──────────
# Checks only the lines ADDED in the commit, ignoring tests/examples.
echo ""
echo "▶ Looking for hardcoded credentials in staged changes..."
SECRET_RE="(password|passwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$\{][^\"']{3,}[\"']|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,}"
LEAKS=$(git diff --cached -U0 --no-color \
  -- . ':!*test*' ':!*spec*' ':!*example*' ':!*sample*' ':!*.md' ':!*.lock' ':!*lock.json' \
  2>/dev/null | grep -E '^\+[^+]' | grep -Eiv 'os\.environ|process\.env|getenv|\$\{' | grep -Ei "$SECRET_RE")
if [ -n "$LEAKS" ]; then
  echo "$LEAKS" | cut -c1-160
  echo "  ✗ Possible hardcoded credentials (use environment variables)"
  ERRORS=$((ERRORS + 1))
else
  echo "  ✓ Sin credenciales hardcodeadas"
fi

# ─── Final result ─────────────────────────────────────────
echo ""
echo "======================================="
if [ $ERRORS -eq 0 ]; then
  echo "  ✓ All OK — proceeding with the commit"
  echo "======================================="
  echo ""
  exit 0
else
  echo "  ✗ $ERRORS problema(s) encontrado(s)"
  echo "  Fix the errors before committing."
  echo "======================================="
  echo ""
  exit 2
fi
