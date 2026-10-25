#include <stdio.h>
extern int owned_framework_value(int);
int main(int argc, char **argv) { (void)argv; puts("Owned SDK signing fixture"); return owned_framework_value(argc); }
