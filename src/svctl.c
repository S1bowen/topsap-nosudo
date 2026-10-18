/* svctl - drive the TopSAP engine over its SysV shared-memory channel.
 * Layout recovered from sv_websrv (sha256 668c89e5...):
 *   ftok("/tmp/TopSAP_ELE/.BUFF", 0x17); shmget(key, 0x80030, IPC_CREAT|0666)
 *   +0x00 int32 flag: 0 idle | 1 command ready | 2 taken | 3 response ready
 *   +0x08 pthread_mutex_t (response writer only)
 *   +0x30 char data[0x80000]: request JSON in, response JSON out
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define BUF_PATH "/tmp/TopSAP_ELE/.BUFF"
#define PROJ_ID  0x17
#define SHM_SIZE 0x80030
#define DATA_OFF 0x30
#define DATA_LEN 0x80000
#define MAX_CMD  0x1000

static void nap(long ms){ struct timespec t={ms/1000,(ms%1000)*1000000L}; nanosleep(&t,NULL); }

int main(int argc, char **argv){
  int watch = 0, watch_s = 30, i;
  for (i = 1; i < argc; i++){
    if (!strcmp(argv[i], "-w") && i+1 < argc){ watch = 1; watch_s = atoi(argv[i+1]); i++; }
    else break;
  }
  if (i >= argc){ fprintf(stderr,"usage: svctl [-w SECONDS] '<json>'|@file\n"); return 2; }
  if (argc < 2){ fprintf(stderr,"usage: svctl '<json>'\n"); return 2; }
  static char fbuf[MAX_CMD];
  const char *cmd = argv[i];
  if (cmd[0] == '@'){                      /* read command from a file */
    FILE *fp = fopen(cmd+1, "rb");
    if (!fp){ perror("svctl: open"); return 2; }
    size_t n = fread(fbuf, 1, sizeof(fbuf)-1, fp);
    fclose(fp); fbuf[n] = 0;
    while (n && (fbuf[n-1]=='\n' || fbuf[n-1]=='\r')) fbuf[--n] = 0;
    cmd = fbuf;
  }
  if (strlen(cmd) >= MAX_CMD){ fprintf(stderr,"svctl: command too long\n"); return 2; }

  key_t key = ftok(BUF_PATH, PROJ_ID);
  if (key == (key_t)-1){ perror("ftok"); return 1; }
  int id = shmget(key, SHM_SIZE, IPC_CREAT|0666);
  if (id == -1){ perror("shmget"); return 1; }
  char *b = shmat(id, NULL, 0);
  if (b == (char*)-1){ perror("shmat"); return 1; }

  volatile int *flag = (volatile int *)b;
  char *data = b + DATA_OFF;
  int n;

  for (n = 0; n < 50 && (*flag == 1 || *flag == 2); n++) nap(100);  /* wait busy peer */
  *flag = 0;
  memcpy(data, cmd, strlen(cmd) + 1);
  __sync_synchronize();
  *flag = 1;                                    /* command ready */

  if (!watch){
    for (n = 0; n < 600; n++){                  /* up to 60 s */
      if (*flag == 3) break;
      nap(100);
    }
    if (*flag != 3){ fprintf(stderr,"svctl: timeout (flag=%d)\n", *flag); return 3; }
    fwrite(data, 1, strnlen(data, DATA_LEN), stdout);
    fputc('\n', stdout);
    shmdt(b);
    return 0;
  }
  /* watch mode: print every response the engine pushes until the deadline */
  {
    int got = 0, ticks = watch_s * 10;
    for (n = 0; n < ticks; n++){
      if (*flag == 3){
        size_t L = strnlen(data, DATA_LEN);
        printf("[%4d] ", ++got);
        fwrite(data, 1, L, stdout);
        fputc('\n', stdout);
        fflush(stdout);
        *flag = 0;
        n = 0;                                  /* restart the idle window */
        if (L == 0) { } else { /* keep listening */ }
      }
      nap(100);
    }
    if (!got) fprintf(stderr,"svctl: no response within %d s\n", watch_s);
    shmdt(b);
    return got ? 0 : 3;
  }
}
