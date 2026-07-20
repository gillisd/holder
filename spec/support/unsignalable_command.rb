require "tmpdir"

##
# The command the specs run when they need a real process group that a non-root
# supervisor genuinely cannot signal (every kill raises EPERM): a throwaway
# setuid-root helper whose *leader* drops to +nobody+ and then execs +sleep+.
# path builds it once and returns where it landed, or nil when the host can't
# provide one -- no passwordless sudo, no C compiler, a nosuid mount, or running
# as root (which can signal anyone) -- so the example skips instead of failing.
# remove tears it back down.
module UnsignalableCommand
  NOBODY = 65_534
  BIN = "/usr/local/bin/holder_spec_drop_sleep".freeze
  SOURCE = <<~C.freeze
    #include <unistd.h>
    #include <grp.h>
    int main(void) {
      setgroups(0, 0);
      setgid(#{NOBODY});
      if (setuid(#{NOBODY}) != 0) return 2;
      execlp("sleep", "sleep", "300", (char *)0);
      return 3;
    }
  C

  module_function

  def path
    return @path if defined?(@path)

    @path = usable_host? && install && drops_to_nobody? ? BIN : nil
  end

  def remove
    quietly("sudo", "-n", "rm", "-f", BIN)
  end

  def usable_host?
    !Process.uid.zero? && which("cc") && quietly("sudo", "-n", "true")
  end

  def install
    source = File.join(Dir.tmpdir, "holder_spec_drop_sleep.c")
    File.write(source, SOURCE)
    quietly("sudo", "-n", "cc", "-O2", "-o", BIN, source) &&
      quietly("sudo", "-n", "chown", "root:root", BIN) &&
      quietly("sudo", "-n", "chmod", "4755", BIN)
  end

  def drops_to_nobody?
    pid = spawn(BIN, out: File::NULL, err: File::NULL)
    sleep 0.2
    dropped = IO.popen(["ps", "-o", "uid=", "-p", pid.to_s], &:read).strip == NOBODY.to_s
    quietly("sudo", "-n", "kill", "-KILL", pid.to_s)
    dropped
  end

  def which(cmd)
    quietly("sh", "-c", "command -v #{cmd}")
  end

  def quietly(*argv)
    system(*argv, out: File::NULL, err: File::NULL)
  end
end
