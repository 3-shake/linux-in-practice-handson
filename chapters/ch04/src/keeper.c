#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>

#include "enc.h" /* setup.sh が生成: XOR 0x5A 済みフラグの byte 配列 enc[] */

/* 無名メモリ領域に名前を付ける prctl。カーネル 5.17+ で有効 */
#ifndef PR_SET_VMA
#define PR_SET_VMA 0x53564d41
#endif
#ifndef PR_SET_VMA_ANON_NAME
#define PR_SET_VMA_ANON_NAME 0
#endif

int main(void)
{
    /* mmap() で 64MiB の無名メモリ領域を仮想アドレス空間に確保する。
     * デマンドページングにより、実際に触るまで物理メモリは割り当てられない。 */
    size_t len = 64UL * 1024 * 1024;
    unsigned char *m = mmap(NULL, len, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED)
        return 1;

    /* この無名領域に名前を付ける(/proc/<pid>/maps に [anon:flag_vault] で見える) */
    prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, (unsigned long)m, len, "flag_vault");

    /* enc[] を復号して先頭ページにだけ書き込む。
     * → このページだけに物理メモリが割り当てられる(RSS はごく僅か、VSZ は 64MiB) */
    for (size_t i = 0; i < sizeof(enc); i++)
        m[i] = enc[i] ^ 0x5A;

    printf("ch04-keeper 稼働中 (pid=%d)。結果は自分のメモリ上に保管しました。\n", getpid());
    fflush(stdout);

    /* シグナルを待ちながら常駐しつづける */
    for (;;)
        pause();
    return 0;
}
