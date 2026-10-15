#include "anydoc_ffi.h"
#include <stdio.h>
#include <string.h>

int main(void) {
  const char input[] = "name,value\nalpha,1\n";
  const char expected[] = "| name | value |\n| --- | --- |\n| alpha | 1 |\n";
  char *markdown = NULL;
  char *error_message = NULL;
  const char *error_code = NULL;
  int status = anydoc_to_markdown((const uint8_t *)input, strlen(input), "csv",
                                  &markdown, &error_code, &error_message);
  int failed = status != ANYDOC_OK || markdown == NULL || strcmp(markdown, expected) != 0;
  if (failed) fprintf(stderr, "Anydoc native CSV smoke test failed: status %d\n", status);
  anydoc_string_free(markdown);
  anydoc_string_free(error_message);
  return failed;
}
