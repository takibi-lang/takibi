#include <stdio.h>

extern int foo(int c);
extern int bar(int a, int b);

int main(void) {
    printf("foo(5)       = %d\n", foo(5));
    printf("bar(3, 4)    = %d\n", bar(3, 4));  /* 2*3+1=7 > 4 → while(r!=0) skipped → return r=0 */
    printf("bar(1, 10)   = %d\n", bar(1, 10)); /* 2*1+1=3 > 10 false → r = g_int = 1 → return 1 */
    return 0;
}
