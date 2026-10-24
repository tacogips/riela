#ifndef CRIELA_PUBLIC_WEB_H
#define CRIELA_PUBLIC_WEB_H
#include <stddef.h>
#include <libxml/HTMLparser.h>
#include <libxml/parser.h>
#include <libxml/tree.h>

typedef struct riela_web_cancel riela_web_cancel;
typedef struct {
  int error; /* 0=ok,1=invalid,2=nonpublic,3=transport,4=oversized,5=cancelled,6=timeout */
  long status;
  unsigned char *body;
  size_t body_length;
  char *headers;
  size_t headers_length;
} riela_web_response;

riela_web_cancel *riela_web_cancel_create(void);
void riela_web_cancel_set(riela_web_cancel *value);
void riela_web_cancel_free(riela_web_cancel *value);
int riela_web_public_ip(const char *ip);
riela_web_response riela_web_fetch(const char *url, const char *host, const char *conditional_headers,
  size_t max_body_bytes, long timeout_ms, riela_web_cancel *cancel);
void riela_web_response_free(riela_web_response *response);
xmlDocPtr riela_web_parse_html(const char *bytes, int count);
xmlDocPtr riela_web_parse_xml(const char *bytes, int count);
void riela_web_xml_string_free(xmlChar *value);
#endif
