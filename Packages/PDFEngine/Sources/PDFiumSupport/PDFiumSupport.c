#include "PDFiumSupport.h"

#include <stdio.h>

#include "fpdf_save.h"

typedef struct {
  FPDF_FILEWRITE base;
  FILE *file;
} ClipPDFiumFileWriter;

static int ClipPDFiumWriteBlock(FPDF_FILEWRITE *base,
                                const void *data,
                                unsigned long size) {
  ClipPDFiumFileWriter *writer = (ClipPDFiumFileWriter *)base;
  return fwrite(data, 1, size, writer->file) == size;
}

int ClipPDFiumSaveDocumentToPath(void *document,
                                const char *path,
                                unsigned int flags) {
  FILE *file = fopen(path, "wb");
  if (!file) {
    return 0;
  }
  ClipPDFiumFileWriter writer = {
      .base = {.version = 1, .WriteBlock = ClipPDFiumWriteBlock},
      .file = file,
  };
  int result = FPDF_SaveAsCopy((FPDF_DOCUMENT)document, &writer.base, flags);
  if (fclose(file) != 0) {
    return 0;
  }
  return result;
}
