defmodule Platform.Tools.MountTest do
  use ExUnit.Case, async: true

  alias Platform.Tools.Mount

  test "shioud return correct mountpoint of partition" do
    assert "mmcblk0p3" =
             "/root"
             |> Mount.device(&fixtrure/0)
  end

  def fixtrure,
    do: """
    /dev/root on / type squashfs (ro,relatime)
    devtmpfs on /dev type devtmpfs (rw,nosuid,noexec,relatime,size=1024k,nr_inodes=438771,mode=755)
    proc on /proc type proc (rw,nosuid,nodev,noexec,relatime)
    sysfs on /sys type sysfs (rw,nosuid,nodev,noexec,relatime)
    devpts on /dev/pts type devpts (rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000)
    tmpfs on /tmp type tmpfs (rw,nosuid,nodev,noexec,relatime,size=377388k)
    tmpfs on /run type tmpfs (rw,nosuid,nodev,noexec,relatime,size=188696k,mode=755)
    /dev/mmcblk0p1 on /boot type vfat (ro,nosuid,nodev,noexec,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro)
    /dev/mmcblk0p3 on /root type f2fs (rw,lazytime,nodev,relatime,background_gc=on,discard,no_heap,user_xattr,inline_xattr,acl,inline_data,inline_dentry,flush_merge,extent_cache,mode=adaptive,active_logs=6,alloc_mode=reuse,fsync_mode=posix)
    pstore on /sys/fs/pstore type pstore (rw,nosuid,nodev,noexec,relatime)
    tmpfs on /sys/fs/cgroup type tmpfs (rw,nosuid,nodev,noexec,relatime,size=1024k,mode=755)
    cpu on /sys/fs/cgroup/cpu type cgroup (rw,nosuid,nodev,noexec,relatime,cpu)
    """
end
