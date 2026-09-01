#include "my_application.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/file.h>
#include <unistd.h>

#include <glib.h>

namespace {

// GApplication uniqueness is scoped to the session bus. Two graphical
// sessions (or dbus-run-session shells) sharing $HOME can both become
// primary and then race startup recovery on the same documents/cache.
// Hold a user-data flock for the process lifetime as a second line of
// defense that does not depend on D-Bus.
int AcquireSingleInstanceLock() {
  g_autofree gchar* dir =
      g_build_filename(g_get_user_data_dir(), APPLICATION_ID, nullptr);
  if (g_mkdir_with_parents(dir, 0700) != 0 && errno != EEXIST) {
    return -1;
  }
  g_autofree gchar* path =
      g_build_filename(dir, "single_instance.lock", nullptr);
  const int fd = open(path, O_RDWR | O_CREAT, 0600);
  if (fd < 0) {
    return -1;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

}  // namespace

int main(int argc, char** argv) {
  const int lock_fd = AcquireSingleInstanceLock();
  if (lock_fd < 0) {
    // Another process already owns the artifact stores for this account.
    return EXIT_SUCCESS;
  }

  g_autoptr(MyApplication) app = my_application_new();
  const int status = g_application_run(G_APPLICATION(app), argc, argv);
  close(lock_fd);
  return status;
}
