/* svdbg: instrumented SHM client for the TopSAP sv_websrv command plane.
 *
 * Usage: svdbg [-t SECONDS] JSON | svdbg [-t SECONDS] @FILE
 *
 * Prints ftok/shmid, every flag transition with a realtime timestamp, the
 * response length and raw bytes, and then keeps watching for -t seconds
 * (default 2.0) so late second-shot responses or an engine death are visible.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define BUF_PATH "/tmp/TopSAP_ELE/.BUFF"
#define PROJ_ID  0x17
#define SHM_SIZE 0x80030
#define DATA_OFF 0x30
#define DATA_LEN 0x80000

static double now(void){ struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return ts.tv_sec + ts.tv_nsec/1e9; }

static void raw(const char *tag, const unsigned char *p){
  printf("    %s bytes: ", tag);
  for (int i=0;i<32;i++) printf("%02x", p[i]);
  printf("\n");
}

int main(int argc, char **argv){
  double tail = 2.0;
  int a = 1;
  if (argc > 3 && strcmp(argv[1], "-t") == 0){ tail = atof(argv[2]); a = 3; }
  if (argc <= a){ fprintf(stderr,"usage: svdbg [-t SECONDS] JSON|@FILE\n"); return 2; }

  static char cmd[DATA_LEN];
  if (argv[a][0] == '@'){
    FILE *f = fopen(argv[a]+1, "r");
    if (!f){ perror("open req"); return 2; }
    size_t n = fread(cmd, 1, sizeof(cmd)-1, f);
    cmd[n] = 0; fclose(f);
    for (size_t i=0;i<n;i++) if (cmd[i]=='\n' || cmd[i]=='\r') cmd[i] = 0;
  } else {
    snprintf(cmd, sizeof(cmd), "%s", argv[a]);
  }

  key_t key = ftok(BUF_PATH, PROJ_ID);
  printf("[t=%.3f] ftok key=0x%x\n", now(), (unsigned)key);
  if (key==(key_t)-1){ perror("ftok"); return 2; }

  int id = shmget(key, SHM_SIZE, IPC_CREAT|0666);
  if (id<0){ perror("shmget"); return 2; }
  printf("[t=%.3f] shmid=%d\n", now(), id);

  char *b = shmat(id, NULL, 0);
  if (b==(char*)-1){ perror("shmat"); return 2; }
  volatile int *flag = (volatile int *)b;
  char *data = b + DATA_OFF;

  printf("[t=%.3f] entry flag=%d\n", now(), *flag);

  int n;
  for (n=0; n<50 && (*flag==1 || *flag==2); n++) usleep(100000);
  if (n) printf("[t=%.3f] waited %d00ms for flag to clear, flag=%d\n", now(), n, *flag);

  *flag = 0;
  memset(data, 0, DATA_LEN);
  memcpy(data, cmd, strnlen(cmd, DATA_LEN-1));
  __sync_synchronize();
  *flag = 1;
  printf("[t=%.3f] sent %zu bytes: %.60s%s\n", now(), strlen(cmd), cmd, strlen(cmd) > 60 ? "..." : "");

  int last = 1, shots = 0, len = 0;
  double t0 = now(), tshot = 0;
  for (;;){
    int f = *flag;
    if (f != last){ printf("[t=%.3f] flag %d -> %d\n", now(), last, f); last = f; }
    if (f == 3){
      len = 0;
      while (len < DATA_LEN && data[len]) len++;
      shots++;
      printf("[t=%.3f] RESPONSE #%d len=%d\n", now(), shots, len);
      if (len > 0){ fwrite(data, 1, len > 4096 ? 4096 : len, stdout); printf("\n"); }
      else raw("empty", (const unsigned char*)data);
      tshot = now();
      *flag = 0;                   /* consume, so a second shot is distinguishable */
      last = 0;
    }
    if (shots && now() - tshot > tail){
      printf("[t=%.3f] tail window over: %d shot(s), final flag=%d\n", now(), shots, *flag);
      return 0;
    }
    if (!shots && now() - t0 > 25.0){ printf("[t=%.3f] TIMEOUT flag=%d\n", now(), *flag); return 3; }
    usleep(20000);
  }
}
