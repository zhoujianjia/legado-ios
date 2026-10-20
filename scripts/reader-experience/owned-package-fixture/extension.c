#include <stdio.h>
extern int owned_framework_value(int);
int main(int argc, char **argv) { (void)argv; puts("Owned extension SDK fixture"); return owned_framework_value(argc + 1); }
