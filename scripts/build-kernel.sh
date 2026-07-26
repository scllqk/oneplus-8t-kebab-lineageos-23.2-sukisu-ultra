#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_DIR="${KERNEL_DIR:-${ROOT_DIR}/kernel}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
DIST_DIR="${ROOT_DIR}/dist"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${ROOT_DIR}/toolchain}"

: "${KERNEL_REF:=lineage-23.2}"
: "${SUKISU_REF:=v4.1.3}"
: "${CLANG_VERSION:=clang-r563880c}"

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=github

mkdir -p "${OUT_DIR}" "${DIST_DIR}"

echo "Integrating SukiSU-Ultra ${SUKISU_REF}"
(
  cd "${KERNEL_DIR}"
  curl --fail --location --silent --show-error \
    "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${SUKISU_REF}/kernel/setup.sh" \
    | sh -s "${SUKISU_REF}"
)

echo ""
echo "=== Integrating SUSFS (simonpunk susfs4ksu) ==="
SUSFS_DIR="${KERNEL_DIR}/susfs4ksu"
rm -rf "${SUSFS_DIR}"

echo "Fetching susfs4ksu from GitLab (kernel-4.19 branch)"
git clone --depth=1 --branch kernel-4.19 \
  https://gitlab.com/simonpunk/susfs4ksu.git "${SUSFS_DIR}"

echo "Applying SUSFS main kernel 4.19 patch"
git -C "${KERNEL_DIR}" apply --verbose \
  "${SUSFS_DIR}/kernel_patches/50_add_susfs_in_kernel-4.19.patch"

# Copy the SUSFS source files
if [ -d "${SUSFS_DIR}/kernel_patches/fs" ]; then
  cp -v "${SUSFS_DIR}/kernel_patches/fs/susfs.c"   "${KERNEL_DIR}/fs/susfs.c" 2>/dev/null || true
  cp -v "${SUSFS_DIR}/kernel_patches/fs/sus_su.c"  "${KERNEL_DIR}/fs/sus_su.c" 2>/dev/null || true
fi
if [ -d "${SUSFS_DIR}/kernel_patches/include" ]; then
  cp -rv "${SUSFS_DIR}/kernel_patches/include/linux/"* "${KERNEL_DIR}/include/linux/" 2>/dev/null || true
fi

echo "SUSFS source files integrated"
rm -rf "${SUSFS_DIR}"
echo "=== SUSFS integration complete ==="

echo "Backporting path_umount for Linux 4.19"
if ! grep -q '^int path_umount(struct path \*path, int flags)' \
  "${KERNEL_DIR}/fs/namespace.c"; then
  git -C "${KERNEL_DIR}" apply "${ROOT_DIR}/patches/path-umount-4.19.patch"
fi

echo "Applying the Linux 4.19 access_ok compatibility shim for SukiSU-Ultra KPM"
if ! grep -q '^static inline bool sukisu_access_ok_compat' \
  "${KERNEL_DIR}/KernelSU/kernel/kpm/kpm.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-kpm-access-ok-4.19.patch"
fi

echo "Backporting MODULE_IMPORT_NS compatibility for SukiSU-Ultra"
if ! grep -q '^#define MODULE_IMPORT_NS(ns)' \
  "${KERNEL_DIR}/KernelSU/kernel/core/init.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-module-import-ns-4.19.patch"
fi

echo "Disabling unavailable VFS wrapper methods on Linux 4.19"
if ! grep -q '^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)$' \
  "${KERNEL_DIR}/KernelSU/kernel/infra/file_wrapper.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-file-wrapper-4.19.patch"
fi

echo "Backporting the native seccomp syscall count for Linux 4.19"
if ! grep -q '^#define SECCOMP_ARCH_NATIVE_NR __NR_syscalls' \
  "${KERNEL_DIR}/KernelSU/kernel/infra/seccomp_cache.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-seccomp-nr-4.19.patch"
fi

echo "Using the Linux 4.19 mount header layout for SukiSU-Ultra"
if grep -q '^#include <uapi/linux/mount.h>' \
  "${KERNEL_DIR}/KernelSU/kernel/infra/su_mount_ns.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-mount-header-4.19.patch"
fi

echo "Backporting the Linux 4.19 fsnotify observer callback"
if ! grep -q '^static int ksu_handle_event(struct fsnotify_group' \
  "${KERNEL_DIR}/KernelSU/kernel/manager/pkg_observer.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-fsnotify-4.19.patch"
fi

echo "Backporting the Linux 4.19 task_work API for SukiSU-Ultra"
if ! grep -q '^#define KSU_TWA_RESUME true' \
  "${KERNEL_DIR}/KernelSU/kernel/policy/allowlist.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-task-work-4.19.patch"
fi

echo "Gating the newer seccomp filter counter on Linux 4.19"
if ! grep -q '^#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)$' \
  "${KERNEL_DIR}/KernelSU/kernel/policy/app_profile.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-seccomp-filter-count-4.19.patch"
fi

echo "Backporting the Linux 4.19 SELinux policy layout for SukiSU-Ultra"
if ! grep -q '^static DEFINE_MUTEX(ksu_rules);' \
  "${KERNEL_DIR}/KernelSU/kernel/selinux/rules.c"; then
  git -C "${KERNEL_DIR}/KernelSU" apply \
    "${ROOT_DIR}/patches/sukisu-selinux-policy-4.19.patch"
fi

echo "Using the Linux 4.19 SELinux policydb implementation"
cp "${ROOT_DIR}/compat/sukisu/sepolicy-4.19.c" \
  "${KERNEL_DIR}/KernelSU/kernel/selinux/sepolicy.c"

make_args=(
  -C "${KERNEL_DIR}"
  O="${OUT_DIR}"
  ARCH=arm64
  LLVM=1
  LLVM_IAS=1
  CC=clang
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  STRIP=llvm-strip
  HOSTCC=clang
  HOSTCXX=clang++
  DTC_EXT=dtc
  BRAND_SHOW_FLAG=oneplus
)

echo "Generating the LineageOS kernel configuration"
cp "${KERNEL_DIR}/arch/arm64/configs/vendor/kona-perf_defconfig" "${OUT_DIR}/.config"
make "${make_args[@]}" olddefconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" \
  "${KERNEL_DIR}/arch/arm64/configs/vendor/oplus.config"
make "${make_args[@]}" olddefconfig
"${KERNEL_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" \
  "${ROOT_DIR}/configs/sukisu-ultra.config"
make "${make_args[@]}" olddefconfig

# Force-set SUSFS options (olddefconfig drops unknown Kconfig symbols from simonpunk patches)
echo "=== Force-setting SUSFS options ==="
for opt in \
  CONFIG_KSU_SUSFS=y \
  CONFIG_KSU_SUSFS_SUS_PATH=y \
  CONFIG_KSU_SUSFS_SUS_MOUNT=y \
  CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y \
  CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y \
  CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y \
  CONFIG_KSU_SUSFS_TRY_UMOUNT=y \
  CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
  CONFIG_KSU_SUSFS_ENABLE_LOG=y \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y \
  CONFIG_KSU_SUSFS_OPEN_REDIRECT=y \
  CONFIG_KSU_SUSFS_SUS_KSTAT=y \
  CONFIG_KSU_SUSFS_SUS_SU=y; do
  name="${opt%=*}"; val="${opt#*=}"
  if grep -q "^${name}=" "${OUT_DIR}/.config"; then
    sed -i "s|^${name}=.*|${name}=${val}|" "${OUT_DIR}/.config"
  else
    echo "${name}=${val}" >> "${OUT_DIR}/.config"
  fi
  echo "  ${name}=${val}"
done

# Disable debug/trace features (hardening)
echo "=== Disabling debug features ==="
for opt in \
  CONFIG_DEBUG_FS=n \
  CONFIG_PROC_KCORE=n \
  CONFIG_DEBUG_KERNEL=n \
  CONFIG_DEBUG_INFO=n; do
  name="${opt%=*}"; val="${opt#*=}"
  if grep -q "^${name}=" "${OUT_DIR}/.config"; then
    sed -i "s|^${name}=.*|${name}=${val}|" "${OUT_DIR}/.config"
  else
    echo "${name}=${val}" >> "${OUT_DIR}/.config"
  fi
  echo "  ${name}=${val}"
done

for required in \
  CONFIG_KSU=y \
  CONFIG_KSU_MANUAL_SU=y \
  CONFIG_KSU_SUSFS=y \
  CONFIG_KPM=y \
  CONFIG_KPROBES=y \
  CONFIG_KRETPROBES=y \
  CONFIG_HAVE_SYSCALL_TRACEPOINTS=y \
  CONFIG_KALLSYMS=y \
  CONFIG_KALLSYMS_ALL=y \
  CONFIG_EXT4_FS=y \
  CONFIG_OVERLAY_FS=y; do
  grep -qx "${required}" "${OUT_DIR}/.config" || {
    echo "Required setting is missing after olddefconfig: ${required}" >&2
    exit 1
  }
done

echo "Building Image"
make -j"$(nproc)" "${make_args[@]}" Image

image_path="${OUT_DIR}/arch/arm64/boot/Image"
test -s "${image_path}"
cp "${image_path}" "${DIST_DIR}/Image"
cp "${OUT_DIR}/.config" "${DIST_DIR}/kernel.config"

kernel_sha="$(git -C "${KERNEL_DIR}" rev-parse HEAD)"
sukisu_sha="$(git -C "${KERNEL_DIR}/KernelSU" rev-parse HEAD)"
kernel_release="$(make -s "${make_args[@]}" kernelrelease)"

cat > "${DIST_DIR}/build-info.txt" <<EOF
device=kebab
rom=lineage-23.2
kernel_repository=https://github.com/LineageOS/android_kernel_oneplus_sm8250
kernel_ref=${KERNEL_REF}
kernel_commit=${kernel_sha}
kernel_release=${kernel_release}
sukisu_repository=https://github.com/SukiSU-Ultra/SukiSU-Ultra
sukisu_ref=${SUKISU_REF}
sukisu_commit=${sukisu_sha}
clang_version=${CLANG_VERSION}
compiler=$(clang --version | head -n 1)
EOF

echo "KERNEL_SHA=${kernel_sha}" >> "${GITHUB_ENV}"
echo "SUKISU_SHA=${sukisu_sha}" >> "${GITHUB_ENV}"
echo "KERNEL_RELEASE=${kernel_release}" >> "${GITHUB_ENV}"
