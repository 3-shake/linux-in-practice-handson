/* perfsyncd — 「性能データ同期デーモン」を名乗る、CPU を譲らない常駐プロセス。
 * 問題2の犯人。systemd unit (perfsync.service) から taskset -c 1 で
 * nice 0 のまま起動され、busy 60ms + sleep 40ms のデューティサイクルで
 * 論理CPU1 を約6割使い続ける。100% 張り付きにしないのは、現実の
 * 「重い同期処理」に寄せるためと、バーストクレジットの消費を抑えるため。
 */
#include <time.h>

static long elapsed_ms(const struct timespec *a, const struct timespec *b)
{
	return (b->tv_sec - a->tv_sec) * 1000 +
	       (b->tv_nsec - a->tv_nsec) / 1000000;
}

int main(void)
{
	volatile unsigned long x = 0;
	struct timespec start, now;
	const struct timespec rest = { 0, 40 * 1000 * 1000 };

	for (;;) {
		clock_gettime(CLOCK_MONOTONIC, &start);
		do {
			for (int i = 0; i < 100000; i++)
				x++;
			clock_gettime(CLOCK_MONOTONIC, &now);
		} while (elapsed_ms(&start, &now) < 60);
		nanosleep(&rest, 0);
	}
	return 0;
}
