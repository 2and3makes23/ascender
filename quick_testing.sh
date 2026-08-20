#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-${BASE_DIR}/venv}"
VENV_PYTHON="${VENV_DIR}/bin/python"

# uv's official install documentation, referenced when uv is not available.
UV_INSTALL_DOCS_URL="https://docs.astral.sh/uv/getting-started/installation/"

# ---------------------------------------------------------------------------
# --help output (usage, options, environment overrides, covered test suites)
# ---------------------------------------------------------------------------
print_help() {
    cat <<EOF
quick_testing.sh -- set up (or reuse) the test venv and run ascender's pytest suites.

Sets up a local Python virtual environment, installs all dependencies needed
by the ascender Python packages and their tests, and (by default) runs the
"all" test suite -- the same set the Makefile's TEST_DIRS covers:

  all: awx/main/tests/{unit,functional}  awx/conf/tests  awx/sso/tests

Usage:
  bash quick_testing.sh                          # ensure env + run the full suite
  bash quick_testing.sh --unit                   # run only the unit test trees
  bash quick_testing.sh --pkg conf               # run the awx/conf package tests
  bash quick_testing.sh --no-update --sso        # quick repeat: reuse the venv, sso only
  bash quick_testing.sh --no-run                 # only create/upgrade the environment
  bash quick_testing.sh --list                   # list the available suites and exit
  bash quick_testing.sh -- <pytest args>         # ensure env + run tests with extra args
  bash quick_testing.sh --uv / --legacy          # force the provisioning path
  bash quick_testing.sh --help                   # show this help text and exit

Test suite selection (last --<lane> wins; default: --all):
  --all           entire project, see above
  --unit          awx/main/tests/unit awx/conf/tests/unit awx/sso/tests/unit
  --functional    awx/main/tests/functional awx/conf/tests/functional awx/sso/tests/functional
  --main          the awx/main package (unit + functional)
  --conf          the awx/conf package (unit + functional)
  --sso           the awx/sso package (unit + functional)
  --pkg <name>    single package: main, conf or sso (same as the matching lane)
  TEST_DIRS=...   explicit space-separated pytest paths, overrides any lane

Coverage check: every run verifies that the "all" lane still covers every
package that ships tests in this checkout (awx/*/tests/{unit,functional}).
If a new package grows a test tree that the manifest does not include, a
warning is printed; --strict-coverage turns that warning into exit 1 (CI).

Options:
  --help, -h          Print this help text and exit.  Wins over all other flags.
  --list              Print the available suites and exit.
  --all/--unit/--functional/--main/--conf/--sso
                      Select the test suite to run (see above).  Default: --all.
  --pkg <name>        Select a single package's tests (main, conf or sso).
  --strict-coverage   Fail (exit 1) if the "all" lane no longer covers every
                      package that ships tests.
  --no-run            Only create/upgrade the environment; do not run the tests
                      (prints the exact command to run them later).
  --no-update         Skip all environment setup/update (venv creation, package
                      installs, awx editable install, sanity check) and go
                      straight to the test run.  Requires an existing, seeded
                      venv; errors out with a hint if one is missing.
  --uv / --legacy     Override the provisioning path auto-detection.  The chosen
                      path is kept across runs: an existing venv whose Python
                      version does not match the requested one is recreated
                      automatically, so runs "stay on" the selected path.
  --, then args       Anything after this is passed through to pytest verbatim.

Environment overrides:
  TEST_DIRS          explicit pytest paths to run (overrides any suite selection)
  UV_PYTHON          uv-managed Python version to use (default: 3.12)
  PYTHON3            specific interpreter for the no-uv fallback
                     (default: autodetect 3.12, then 3.11/3.13/3.10/3.9)
  VENV_DIR           venv location (default: ${BASE_DIR}/venv)
  SRC_ONLY_PKGS      packages built from source when NO_BINARY=1
                     (default: cffi,pycparser,psycopg,twilio, matching the Makefile)
  NO_BINARY          "1" forces source builds for SRC_ONLY_PKGS (replicates the
                     Makefile/CI; needs libffi-dev + libpq-dev).  Default "0"
                     allows binary wheels everywhere (fast local installs)
  SKIP_PREREQ_CHECK  "1" bypasses the system build-dependency preflight
  SKIP_AWXDIR_SETUP  "1" disables the test-root preflight (see Notes below), which
                     otherwise auto-creates awx/settings/local_quicktesting.py
  AWX_LOGGING_MODE   logging mode for the test runs (default: stdout, since the
                     'file' mode needs /var/log/tower which local boxes lack)

Notes:
  uv is preferred: it provisions a managed, stable Python (3.9-3.13, the
  pinned dependency set is not tested against Python 3.14) and builds the venv
  without relying on system ensurepip/pip.  Without uv, a legacy system-Python
  venv is used as a fallback.  The preflight checks the C toolchain plus the
  OpenLDAP/Cyrus SASL headers needed to compile python-ldap from source (and,
  when NO_BINARY=1, the libffi/libpq headers).
  The tests run under awx/main/tests/settings_for_test (SQLite + in-memory
  Channels, set by pytest.ini), so no Postgres/Redis are required.  A fresh
  awx_test.sqlite3 is created each run so pytest-django rebuilds the test DB.
  Job/project tests need writable PROJECTS_ROOT and JOBOUTPUT_ROOT dirs; the
  defaults are /var/lib/awx/{projects,job_status}, which local users usually
  cannot create.  A preflight auto-writes the gitignored, dev-only
  awx/settings/local_quicktesting.py (loaded via development.py's
  local_*.py include, so it applies to pytest and dev servers, never
  production) to point those roots inside the checkout.  No file is created
  when /var/lib/awx is writable, or with SKIP_AWXDIR_SETUP=1.
  Excluded by design: awx/main/tests/live (needs live external infra),
  awx/main/tests/manual (case study), and awxkit (its own tox/venv, run via
  'make test').
EOF
}

print_suites() {
    echo "Available test suites (default: all):"
    echo
    printf '  %-14s %s\n' "--all"       "${SUITES[all]}"
    printf '  %-14s %s\n' "--unit"      "${SUITES[unit]}"
    printf '  %-14s %s\n' "--functional" "${SUITES[functional]}"
    printf '  %-14s %s\n' "--main"      "${SUITES[main]}"
    printf '  %-14s %s\n' "--conf"      "${SUITES[conf]}"
    printf '  %-14s %s\n' "--sso"       "${SUITES[sso]}"
    printf '  %-14s %s\n' "--pkg <name>" "main, conf or sso (same as the matching lane)"
    echo
    echo "Or set TEST_DIRS to any explicit space-separated pytest paths."
}

# ---------------------------------------------------------------------------
# Test suite manifest (the curated set): lane name -> pytest paths.  The
# "all" lane is the default and must keep covering every package that ships
# tests; check_suite_coverage() verifies that on every run.
# ---------------------------------------------------------------------------
declare -A SUITES=(
    [all]="awx/main/tests/unit awx/main/tests/functional awx/conf/tests awx/sso/tests"
    [unit]="awx/main/tests/unit awx/conf/tests/unit awx/sso/tests/unit"
    [functional]="awx/main/tests/functional awx/conf/tests/functional awx/sso/tests/functional"
    [main]="awx/main/tests/unit awx/main/tests/functional"
    [conf]="awx/conf/tests"
    [sso]="awx/sso/tests"
)

# Emit the leaf "test tree" paths under each given path: {unit,functional}
# subdirs when present, otherwise the path itself.  Paths are relative to
# BASE_DIR and sorted.
# (Buffered via an array instead of a piped loop: under `set -eo pipefail` a
# short-circuited `[[ -d ]] && echo` would leave a non-zero status on the loop
# subshell and kill the pipeline.)
expand_test_trees() {
    local path out=()
    for path in "$@"; do
        if [[ -d "${BASE_DIR}/${path}/unit" || -d "${BASE_DIR}/${path}/functional" ]]; then
            [[ -d "${BASE_DIR}/${path}/unit" ]] && out+=("${path}/unit")
            [[ -d "${BASE_DIR}/${path}/functional" ]] && out+=("${path}/functional")
        else
            out+=("${path}")
        fi
    done
    printf '%s\n' "${out[@]}" | sort
}

# Every "awx/<pkg>/tests" tree present in the working tree, coarse granularity.
discover_test_trees() {
    local pkg
    for pkg in "${BASE_DIR}"/awx/*/tests; do
        [[ -d "${pkg}" ]] || continue
        expand_test_trees "${pkg#"${BASE_DIR}/"}"
    done
}

# Verify the "all" lane still covers every package that ships tests.  Warns by
# default; --strict-coverage (STRICT_COVERAGE=1) turns drift into exit 1.
check_suite_coverage() {
    local -A discovered=() listed=()
    local tree missing=() extra=() note=""
    while IFS= read -r tree; do discovered["${tree}"]=1; done < <(discover_test_trees)
    while IFS= read -r tree; do listed["${tree}"]=1; done < <(expand_test_trees ${SUITES[all]})

    for tree in "${!discovered[@]}"; do
        [[ -n "${listed[${tree}]+x}" ]] || extra+=("${tree}")
    done
    for tree in "${!listed[@]}"; do
        [[ -n "${discovered[${tree}]+x}" ]] || missing+=("${tree}")
    done

    if [[ "${#missing[@]}" -eq 0 && "${#extra[@]}" -eq 0 ]]; then
        return 0
    fi

    note="The 'all' test lane no longer covers every package with tests in this checkout."
    if [[ "${STRICT_COVERAGE}" == "1" ]]; then
        echo "Error: ${note}" >&2
    else
        echo "Warning: ${note}" >&2
    fi
    echo "Update the SUITES[all] entry in quick_testing.sh (or pass TEST_DIRS) to keep" >&2
    echo "'all' complete." >&2
    if [[ "${#extra[@]}" -gt 0 ]]; then
        echo "Test trees NOT covered by 'all':" >&2
        printf '  - %s\n' "${extra[@]}" | sort >&2
    fi
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "'all' lists trees that no longer exist:" >&2
        printf '  - %s\n' "${missing[@]}" | sort >&2
    fi
    echo "  Re-run with --strict-coverage to fail instead of warning." >&2
    if [[ "${STRICT_COVERAGE}" == "1" ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Test root directories (ensure_test_roots)
#
#    Job/project tests write to settings.PROJECTS_ROOT and
#    settings.JOBOUTPUT_ROOT.  The defaults point at /var/lib/awx/{projects,
#    job_status}, which this box has no permission to create.  development.py
#    (which settings_for_test.py inherits) auto-loads any awx/settings/
#    local_*.py, and awx/settings/local_*.py* is gitignored -- a dedicated
#    local_quicktesting.py is therefore a machine-local, uncommitted way to
#    point those roots inside the checkout.  Auto-create it unless a writable
#    /var/lib/awx already exists or the developer opted out.
# ---------------------------------------------------------------------------
AWX_DIR_OVERRIDE_FILE="${BASE_DIR}/awx/settings/local_quicktesting.py"

ensure_test_roots() {
    local existing=""

    if [[ "${SKIP_AWXDIR_SETUP:-0}" == "1" ]]; then
        existing="$(grep -l 'PROJECTS_ROOT\|JOBOUTPUT_ROOT' "${BASE_DIR}"/awx/settings/local_*.py 2>/dev/null || true)"
    else
        if [[ -d "/var/lib/awx" && -w "/var/lib/awx" ]]; then
            return 0
        fi
        if [[ -f "${AWX_DIR_OVERRIDE_FILE}" ]] && grep -q 'PROJECTS_ROOT' "${AWX_DIR_OVERRIDE_FILE}" && grep -q 'JOBOUTPUT_ROOT' "${AWX_DIR_OVERRIDE_FILE}"; then
            return 0
        fi
        cat > "${AWX_DIR_OVERRIDE_FILE}" <<'PY'
# Auto-generated by quick_testing.sh -- test root overrides (gitignored).
# Points settings.PROJECTS_ROOT / JOBOUTPUT_ROOT inside the checkout so the
# test suites do not need a writable /var/lib/awx.  Loaded via development.py's
# include(optional('local_*.py')), so it applies to pytest runs and dev servers,
# and never to production.  Regenerated by quick_testing.sh when missing.
import os
PROJECTS_ROOT = os.path.join(BASE_DIR, 'projects')
JOBOUTPUT_ROOT = os.path.join(BASE_DIR, 'job_status')
PY
        echo "Created ${AWX_DIR_OVERRIDE_FILE} (gitignored) so tests do not need a writable /var/lib/awx"
        return 0
    fi

    if [[ -z "${existing}" ]]; then
        cat >&2 <<EOF

Warning: SKIP_AWXDIR_SETUP=1 is set, but no awx/settings/local_*.py overrides
PROJECTS_ROOT / JOBOUTPUT_ROOT.  Job/project-path tests will fail unless
/var/lib/awx is writable by this user.
To fix, run once without SKIP_AWXDIR_SETUP (creates the gitignored
${AWX_DIR_OVERRIDE_FILE}), or add the overrides to an existing
awx/settings/local_settings.py yourself.
EOF
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Parse CLI flags before anything else, so --uv/--legacy/--no-update/suite
# choices never leak into the positional args (--no-run / -- <pytest args>)
# handled later.  FORCE_PATH can be "", "uv" or "legacy"; last one wins, as
# does the last suite-selection flag.
# ---------------------------------------------------------------------------
FORCE_PATH=""
NO_UPDATE=0
STRICT_COVERAGE=0
LANE_NAME="all"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_help
            exit 0
            ;;
        --list)
            print_suites
            exit 0
            ;;
        --uv) FORCE_PATH="uv" ; shift ;;
        --legacy) FORCE_PATH="legacy" ; shift ;;
        --no-update) NO_UPDATE=1 ; shift ;;
        --strict-coverage) STRICT_COVERAGE=1 ; shift ;;
        --all) LANE_NAME="all" ; shift ;;
        --unit) LANE_NAME="unit" ; shift ;;
        --functional) LANE_NAME="functional" ; shift ;;
        --main) LANE_NAME="main" ; shift ;;
        --conf) LANE_NAME="conf" ; shift ;;
        --sso) LANE_NAME="sso" ; shift ;;
        --pkg)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Error: --pkg requires a package name (main, conf or sso)." >&2
                exit 1
            fi
            LANE_NAME="$1"
            shift
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        *) POSITIONAL+=("$1") ; shift ;;
    esac
done

if [[ -n "${TEST_DIRS:-}" ]]; then
    read -r -a TEST_PATHS <<< "${TEST_DIRS}"
    SUITE_LABEL="TEST_DIRS"
elif [[ -n "${SUITES[${LANE_NAME}]:-}" ]]; then
    read -r -a TEST_PATHS <<< "${SUITES[${LANE_NAME}]}"
    SUITE_LABEL="${LANE_NAME}"
else
    echo "Error: unknown test suite or package '${LANE_NAME}'." >&2
    echo "Known suites: all, unit, functional, main, conf, sso." >&2
    exit 1
fi

check_suite_coverage

ensure_test_roots

if [[ "${NO_UPDATE}" != "1" ]]; then

# ---------------------------------------------------------------------------
# 1. Choose the provisioning path: uv (featured) or the legacy system-python
#    fallback.
#
# Why uv is preferred:
#   This dev environment needs Python 3.9 - 3.13 (the pinned dependency set
#   is not built/tested against the distro-default Python 3.14), yet the base
#   OS (Ubuntu 26.04) ships no compliant interpreter and the locally installed
#   python3.11 is an pre-release build WITHOUT a working ensurepip/pip.
#   uv solves both at once: it provisions a managed, STABLE Python (default
#   3.12, see UV_PYTHON) into its own user data dir (~/.local/share/uv, not
#   the system), and `uv venv` builds the project venv from it WITHOUT needing
#   ensurepip/pip-package present.  No sudo or apt gymnastics required.
#
# If uv is not installed we print an info message linking to the official
# install documentation, then fall back to the legacy venv path for machines
# that happen to have a compatible system Python.
# ---------------------------------------------------------------------------
if [[ "${FORCE_PATH}" == "legacy" ]]; then
    USE_UV=0
elif command -v uv >/dev/null 2>&1; then
    USE_UV=1
    UV_PYTHON="${UV_PYTHON:-3.12}"
    echo "uv found - using uv-managed Python ${UV_PYTHON}"
elif [[ "${FORCE_PATH}" == "uv" ]]; then
    cat >&2 <<EOF

Error: \`--uv\` was requested, but uv is not installed.
Install uv from the official documentation:
    ${UV_INSTALL_DOCS_URL}
EOF
    exit 1
else
    USE_UV=0
    cat >&2 <<EOF

Info: \`uv\` is not installed.
This script prefers uv because it provisions a managed, stable Python (3.9-3.13)
and creates the virtual environment without relying on the system Python or its
ensurepip/pip packages (both of which are broken/missing on this distro).

Install uv from the official documentation:
    ${UV_INSTALL_DOCS_URL}

Falling back to a system-Python virtualenv if a compatible interpreter exists...
EOF
fi

# Used only by the legacy fallback: pick Python 3.9 - 3.13, preferring 3.12
# (the Makefile's target).  3.14 is deliberately rejected (Django 5.2 caps at
# <6.0 and pins like pytest-xdist==1.34 predate 3.14).
select_python() {
    if [[ -n "${PYTHON3:-}" ]]; then
        command -v "${PYTHON3}" >/dev/null 2>&1 || { echo "PYTHON3=${PYTHON3} not found" >&2; exit 1; }
        echo "${PYTHON3}"
        return
    fi
    for candidate in python3.12 python3.11 python3.13 python3.10 python3.9 python3; do
        command -v "${candidate}" >/dev/null 2>&1 || continue
        version="$("${candidate}" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
        major="${version%%.*}"
        minor="${version##*.}"
        if [[ "${major}" == "3" && "${minor}" -ge 9 && "${minor}" -le 13 ]]; then
            echo "${candidate}"
            return
        fi
    done
    echo "No compatible Python (3.9 - 3.13) found." >&2
    echo "Install uv (${UV_INSTALL_DOCS_URL}) and re-run." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Preflight check for system build dependencies
#
#    Some pinned packages (notably python-ldap, pulled in by django-auth-ldap
#    for the LDAP backend covered by the regression tests this script runs)
#    have no Linux binary wheel and are built from source.
#    Building python-ldap requires a C toolchain plus the OpenLDAP and Cyrus
#    SASL development headers.  Fail fast with an exact install command instead
#    of a confusing mid-install compile error.  When NO_BINARY=1 is set, the
#    cffi/psycopg source builds additionally need the libffi and libpq dev
#    headers, so those are checked too.  uv's managed CPython bundles Python.h,
#    so no `python3-dev` is required on the uv path.
# ---------------------------------------------------------------------------
check_system_prereqs() {
    local missing=()
    local header has_ldap=0 has_sasl=0 has_ffi=0 has_pq=0
    local extra_apt="" extra_dnf="" source_note=""

    if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        missing+=("C toolchain (gcc/make)")
    fi

    # libldap2-dev (openldap-devel on Fedora) ships /usr/include/ldap.h plus
    # the companion lber.h; accept either.
    for header in /usr/include/ldap.h /usr/include/lber.h; do
        if [[ -f "${header}" ]]; then
            has_ldap=1
        fi
    done
    if [[ "${has_ldap}" != "1" ]]; then
        missing+=("OpenLDAP dev headers (libldap2-dev / openldap-devel: /usr/include/ldap.h)")
    fi

    # libsasl2-dev (cyrus-sasl-devel on Fedora) places sasl.h under
    # /usr/include/sasl/ on Debian/Ubuntu, but some distros use a flat
    # /usr/include/sasl.h; accept either.
    for header in /usr/include/sasl.h /usr/include/sasl/sasl.h; do
        if [[ -f "${header}" ]]; then
            has_sasl=1
        fi
    done
    if [[ "${has_sasl}" != "1" ]]; then
        missing+=("Cyrus SASL dev headers (libsasl2-dev / cyrus-sasl-devel: /usr/include/sasl/sasl.h)")
    fi

    # Only relevant when NO_BINARY=1 (SRC_ONLY_PKGS built from source):
    # cffi needs libffi, psycopg needs libpq.  Wheel installs (the default) do
    # not touch these.
    if [[ "${NO_BINARY:-0}" == "1" ]]; then
        extra_apt=" libffi-dev libpq-dev"
        extra_dnf=" libffi-devel libpq-devel"
        source_note="  (when NO_BINARY=1, cffi/psycopg source builds additionally need libffi-dev/libpq-dev)"

        for header in /usr/include/ffi.h /usr/include/x86_64-linux-gnu/ffi.h /usr/include/libffi/ffi.h; do
            if [[ -f "${header}" ]]; then
                has_ffi=1
            fi
        done
        if [[ "${has_ffi}" != "1" ]]; then
            missing+=("libffi dev headers (libffi-dev / libffi-devel: /usr/include/x86_64-linux-gnu/ffi.h)")
        fi

        for header in /usr/include/postgresql/libpq-fe.h /usr/include/libpq-fe.h; do
            if [[ -f "${header}" ]]; then
                has_pq=1
            fi
        done
        if [[ "${has_pq}" != "1" ]]; then
            missing+=("libpq dev headers (libpq-dev / libpq-devel: /usr/include/postgresql/libpq-fe.h)")
        fi
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    cat >&2 <<EOF

Preflight check failed - missing system build dependencies:
EOF
    printf '  - %s\n' "${missing[@]}" >&2
    cat >&2 <<EOF

These are only needed because python-ldap is built from source on this
platform${source_note}.  Install them with:
EOF
    if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get update && sudo apt-get install -y build-essential libldap2-dev libsasl2-dev${extra_apt}" >&2
    elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install gcc make openldap-devel cyrus-sasl-devel${extra_dnf}" >&2
    else
        echo "  the equivalent development packages for your distro (see python-ldap's install docs)." >&2
    fi
    cat >&2 <<EOF

After installing them, re-run this script.
To bypass this check (not recommended), set SKIP_PREREQ_CHECK=1.
EOF
    exit 1
}

if [[ "${SKIP_PREREQ_CHECK:-0}" != "1" ]]; then
    check_system_prereqs
fi

# ---------------------------------------------------------------------------
# 3. Create the virtual environment.
#
#    uv:  `uv venv` downloads a managed ${UV_PYTHON} on first use (stored under
#    ~/.local/share/uv) and creates a standard project-local venv.  The venv
#    directly is the same layout as a `python -m venv`: ${VENV_DIR}/bin/python,
#    lib/python3.x/site-packages, pyvenv.cfg.
#
#    legacy: plain `python -m venv` from the selected system interpreter.
# ---------------------------------------------------------------------------
if [[ "${USE_UV}" == "1" ]]; then
    # Keep the uv path stable across runs: if a venv exists but was created
    # with a different Python (e.g. a leftover 3.11rc1 from the legacy
    # fallback, whose ensurepip/pip are broken and whose ABI breaks source
    # builds like python-ldap), tear it down and rebuild it with uv.
    current_version="$("${VENV_PYTHON}" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    if [[ ! -x "${VENV_PYTHON}" ]]; then
        echo "Creating virtualenv with uv at ${VENV_DIR} (Python ${UV_PYTHON})"
        uv venv --python "${UV_PYTHON}" "${VENV_DIR}"
    elif [[ "${current_version}" != "${UV_PYTHON}" ]]; then
        echo "Existing venv uses Python ${current_version:-unknown}; recreating with uv (Python ${UV_PYTHON}) at ${VENV_DIR}"
        rm -rf "${VENV_DIR}"
        uv venv --python "${UV_PYTHON}" "${VENV_DIR}"
    fi
else
    if [[ ! -x "${VENV_PYTHON}" ]]; then
        LEGACY_PYTHON="$(select_python)"
        echo "Creating virtualenv at ${VENV_DIR} using ${LEGACY_PYTHON}"
        "${LEGACY_PYTHON}" -m venv "${VENV_DIR}"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Install a package set into the venv.
#
#    uv   -> `uv pip install --python ${VENV_PYTHON} ...` (no pip needed inside
#            the venv; uv installs the packages directly).
#    legacy -> `${VENV_DIR}/bin/pip install ...`.
# ---------------------------------------------------------------------------
install_into_venv() {
    if [[ "${USE_UV}" == "1" ]]; then
        uv pip install --python "${VENV_PYTHON}" "$@"
    else
        "${VENV_DIR}/bin/pip" install "$@"
    fi
}

# ---------------------------------------------------------------------------
# 5. (legacy only) Bootstrap pip/setuptools/setuptools_scm/wheel to the exact
#    pins the AWX Makefile uses (Makefile:49 VENV_BOOTSTRAP).
#
#    Why these pins:
#      - pip==26.1.2     PEP 660 `pip install -e .` support (wheel-based editable
#                        installs, required by the modern build backend).
#      - setuptools==83.0.0            referenced by the project's build config.
#      - setuptools_scm[toml]==9.2.2   needed to source the awx package version;
#                        without it the editable install fails to compute a version.
#      - wheel==0.46.2                 build isolation/package baseline.
#
#    The uv path skips this entirely: editable installs run through PEP 517
#    build isolation, where uv fetches setuptools/setuptools_scm/wheel for the
#    isolated build environment on its own.
#    Everything else is installed straight from the project's compiled
#    requirement files so the local environment matches CI exactly.
# ---------------------------------------------------------------------------
if [[ "${USE_UV}" != "1" ]]; then
    echo "Bootstrapping pip/setuptools/setuptools_scm/wheel pins"
    "${VENV_PYTHON}" -m pip install --quiet --upgrade \
        pip==26.1.2 \
        setuptools==83.0.0 \
        'setuptools_scm[toml]==9.2.2' \
        wheel==0.46.2
fi

# ---------------------------------------------------------------------------
# 6. Install the project requirements
#
#    requirements/requirements.txt     compiled, fully-pinned runtime deps
#                                      (Django, djangorestframework, social-auth,
#                                      redis/valkey client, psycopg, ...).
#    requirements/requirements_git.txt MANDATORY.  Pins the git-tracked packages
#                                      used by the SSO code under test:
#                                        - python3-saml       imported by
#                                          awx.sso.saml_pipeline (loaded by the
#                                          unit import test and the sso package)
#                                        - django-ansible-base
#                                        - ansible-runner
#    requirements/requirements_dev.txt dev/test tooling for this very run:
#                                        - pytest* stack  (pytest, pytest-django,
#                                          pytest-timeout, pytest-mock, ...)
#                                          -> pytest-django supplies the
#                                             SQLite test DB + --reuse-db/--nomigrations
#                                        - mockldap (git)  used by test_ldap.py
#                                        - black, flake8, yamllint  linters
#
#    Why the env flags / options:
#      - UWSGI_PROFILE_OVERRIDE=xml=false  stops the uwsgi build picking the xml
#        plugin profile (matches the Makefile's install line).
#      - Binary wheels are used by default: e.g. cffi 2.0.0 ships a CPython 3.12
#        manylinux wheel, so it installs as-is and no system libffi/libpq headers
#        are needed locally.  Set NO_BINARY=1 to replicate the Makefile/CI
#        exactly: SRC_ONLY_PKGS (cffi,pycparser,psycopg,twilio) are then built
#        from source, which requires libffi-dev and libpq-dev (preflight checks
#        these).  Note python-ldap publishes NO Linux wheels at all, so it always
#        builds from source (OpenLDAP/SASL headers, checked by the preflight).
#    Note: the SSO tests run under awx/main/tests/settings_for_test, which uses a
#    SQLite database and an in-memory Channels layer (pytest.ini sets it), so NO
#    Postgres/Redis are required for these suites even though the runtime deps
#    (psycopg, valkey client) are installed.
# ---------------------------------------------------------------------------
INSTALL_OPTIONS=()
if [[ "${NO_BINARY:-0}" == "1" ]]; then
    SRC_ONLY_PKGS="${SRC_ONLY_PKGS:-cffi,pycparser,psycopg,twilio}"
    INSTALL_OPTIONS+=(--no-binary "${SRC_ONLY_PKGS}")
fi

echo "Installing requirements.txt / requirements_git.txt / requirements_dev.txt"
(
    cd "${BASE_DIR}"
    UWSGI_PROFILE_OVERRIDE=xml=false install_into_venv "${INSTALL_OPTIONS[@]}" \
        -r requirements/requirements.txt \
        -r requirements/requirements_git.txt \
        -r requirements/requirements_dev.txt
)

# ---------------------------------------------------------------------------
# 7. Editable install of the awx package itself
#
#    Required so that `import awx` resolves to THIS checkout (and tests always
#    exercise the working tree, including any uncommitted changes).  Without it
#    the import smoke tests and every functional test fail immediately.
# ---------------------------------------------------------------------------
echo "Installing awx in editable mode"
(
    cd "${BASE_DIR}"
    install_into_venv -e .
)

# ---------------------------------------------------------------------------
# 8. Sanity check: awx must import from the venv
# ---------------------------------------------------------------------------
"${VENV_PYTHON}" -c "import awx; print('awx import OK')"

fi  # (NO_UPDATE != 1) -- end of the venv setup/update block

# ---------------------------------------------------------------------------
# --no-update: the setup/update block above was skipped, so make sure the venv
# actually exists and was seeded before running tests against it.
# ---------------------------------------------------------------------------
if [[ "${NO_UPDATE}" == "1" && ! -x "${VENV_PYTHON}" ]]; then
    echo "Error: --no-update requires an existing venv at ${VENV_DIR}." >&2
    echo "Run this script once WITHOUT --no-update to create and seed it, then" >&2
    echo "use --no-update for quick repeat runs." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 9. Run the relevant tests (unless --no-run was given)
#
#    pytest.ini already sets DJANGO_SETTINGS_MODULE + addopts (--reuse-db,
#    --nomigrations), so the suites run out of the box on SQLite.
#    NOTE: pytest-xdist is pinned to 1.34.0 (old) and can choke under modern
#    pytest, so these runs are intentionally serial (`-n` is NOT passed).
#
#    Two extra bits are required for a deterministic local run:
#      - AWX_LOGGING_MODE=stdout  (override with a real value if you want):
#        the default 'file' mode makes Django's logging setup instantiate a
#        WatchedFileHandler per log handler under LOG_ROOT=/var/log/tower, which
#        does not exist on typical local dev boxes (creating it needs root) and
#        aborts django.setup() before any test runs.  'stdout' swaps the file
#        handlers for NullHandler, which is all tests need.
#      - A fresh SQLite test DB: pytest-django's --reuse-db keeps an existing
#        awx_test.sqlite3 across runs, but the ServiceID row that the
#        dab_resource_registry post_save signals require is created by a data
#        migration that --nomigrations skips.  awx/main/tests/functional/conftest.py
#        (mirrored by awx/sso/tests/functional/conftest.py) recreates that row
#        via a post_migrate hook the FIRST time the test DB is created, so we
#        start from a clean file every run.
# ---------------------------------------------------------------------------
RUN_TESTS=1
EXTRA_ARGS=()
if [[ "${#POSITIONAL[@]}" -gt 0 && "${POSITIONAL[0]}" == "--no-run" ]]; then
    RUN_TESTS=0
    POSITIONAL=("${POSITIONAL[@]:1}")
fi
EXTRA_ARGS=("${POSITIONAL[@]}")

export AWX_LOGGING_MODE="${AWX_LOGGING_MODE:-stdout}"

# TEST_PATHS / SUITE_LABEL were resolved from the lane selection (or TEST_DIRS)
# before the environment was set up.

if [[ "${RUN_TESTS}" == "1" ]]; then
    echo "Running test suite '${SUITE_LABEL}'..."
    (
        cd "${BASE_DIR}"
        rm -f awx_test.sqlite3
        "${VENV_PYTHON}" -m pytest "${TEST_PATHS[@]}" -v "${EXTRA_ARGS[@]}"
    )
else
    echo "Requirements are in place. Run the suites with:"
    echo
    echo "  AWX_LOGGING_MODE=${AWX_LOGGING_MODE} rm -f awx_test.sqlite3 \\"
    echo "  ${VENV_PYTHON} -m pytest \\"
    printf '      %s \\\n' "${TEST_PATHS[@]}" | sed '$ s/ \\$//'
    echo
    echo "Or re-run this script without --no-run."
fi
