#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#include "enc.h" /* setup.sh が生成: XOR 0x5A 済みフラグの byte 配列 */

int main(void)
{
    unsigned char buf[sizeof(enc)];

    for (size_t i = 0; i < sizeof(enc); i++)
        buf[i] = enc[i] ^ 0x5A;

    int fd = open("/dev/null", O_WRONLY);
    if (fd < 0)
        return 1;
    if (write(fd, buf, sizeof(buf)) < 0)
        return 1;
    close(fd);

    puts("計算が完了しました。結果は安全な場所に保存されています。");
    return 0;
}
