#include <stdio.h>
__attribute__((visibility("default"))) int owned_framework_value(int value) { puts("Owned framework SDK fixture"); return value + 7; }
