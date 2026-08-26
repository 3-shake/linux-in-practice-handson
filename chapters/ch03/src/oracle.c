#define _GNU_SOURCE /* sched_getaffinity, CPU_* マクロ(glibc)に必要 */

#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>

#include "enc.h" /* setup.sh が生成: XOR 0x37 済みフラグの byte 配列 */

/* 気難しい預言者:
 *   1. 自分が「論理CPU0 だけ」で動くよう縛られていること(taskset)
 *   2. 自分の優先度がいちばん低い側(nice 値 10 以上)であること(nice)
 * の両方を満たしたときだけフラグを口にする。
 */
int main(void)
{
    cpu_set_t set;

    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) != 0) {
        perror("sched_getaffinity");
        return 1;
    }

    if (!(CPU_COUNT(&set) == 1 && CPU_ISSET(0, &set))) {
        long n = sysconf(_SC_NPROCESSORS_CONF);

        puts("私は気分屋の預言者。論理CPUの間をふらふらと移されるのは好かん。");
        puts("私が「論理CPU0」の上だけで動くように縛ってくれたなら、話す気になるかもしれない。");
        printf("(いま私が動ける論理CPU:");
        for (long i = 0; i < n; i++)
            if (CPU_ISSET((int)i, &set))
                printf(" %ld", i);
        puts(")");
        return 1;
    }

    errno = 0;
    int prio = getpriority(PRIO_PROCESS, 0);
    if (prio == -1 && errno != 0) {
        perror("getpriority");
        return 1;
    }
    if (prio < 10) {
        puts("場所は気に入った。だが私は、急かされるのも好かん。");
        puts("優先度を「いちばん低く」下げた状態で、もう一度私を呼びなさい。");
        printf("(いまの私の nice 値: %d)\n", prio);
        return 1;
    }

    puts("……よかろう。論理CPU0 の上で、静かに思い出すとしよう。");
    puts("(数秒かかる。その間に別の端末で sar -P ALL 1 を眺めると、私の働きぶりが見える)");
    fflush(stdout);

    /* time(1) や sar(1) での観察が成立するよう、まとまった量の CPU 時間を使う */
    volatile unsigned long x = 0;
    for (unsigned long i = 0; i < 2000000000UL; i++)
        x += i;
    (void)x;

    char buf[sizeof(enc) + 1];
    for (size_t i = 0; i < sizeof(enc); i++)
        buf[i] = (char)(enc[i] ^ 0x37);
    buf[sizeof(enc)] = '\0';

    printf("これが預言だ: %s\n", buf);
    return 0;
}
