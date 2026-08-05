#ifndef CLIP_PDFIUM_SUPPORT_H_
#define CLIP_PDFIUM_SUPPORT_H_

#ifdef __cplusplus
extern "C" {
#endif

int ClipPDFiumSaveDocumentToPath(void *document, const char *path, unsigned int flags);

#ifdef __cplusplus
}
#endif

#endif
