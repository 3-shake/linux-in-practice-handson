#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#include "enc.h" /* setup.sh が生成: XOR 0x5A 済みフラグの byte 配列 */

static unsigned char buf[sizeof(enc)];

/* フラグを /dev/null に write(2) する。この 1 回の write が観測ポイント。 */
static void emit(void)
{
    int fd = open("/dev/null", O_WRONLY);
    if (fd < 0)
        return;
    if (write(fd, buf, sizeof(buf)) < 0) {
        /* ignore */
    }
    close(fd);
}

/* デーモンは SIGHUP を「設定再読み込み」の合図に使う慣習がある(2章)。
   ここでは HUP を受けたら即座に 1 回 emit する。 */
static void on_hup(int sig)
{
    (void)sig;
    emit();
}

int main(void)
{
    /* デーモンは端末を持たない(2章「デーモン」)。
       対話端末から実行されたら、常駐プロセスを観測するよう促して終了する。 */
    if (isatty(STDOUT_FILENO)) {
        puts("これは常駐して動くデーモンです。対話実行では何もしません。");
        puts("すでに動いているプロセスの振る舞いを観測してください。");
        return 0;
    }

    for (size_t i = 0; i < sizeof(enc); i++)
        buf[i] = enc[i] ^ 0x5A;

    signal(SIGHUP, on_hup);

    /* ほとんどの時間はスリープ状態(STAT=S)。数秒ごとに起きて write する。 */
    for (;;) {
        emit();
        sleep(3);
    }
    return 0;
}
