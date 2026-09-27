#ifndef MICA_DIAGNOSTICS_H
#define MICA_DIAGNOSTICS_H

#import <Foundation/Foundation.h>

void MicaDiagnosticsInitialize(void);
void MicaDiagnosticsLog(NSString *category, NSString *message);
NSURL *MicaDiagnosticsLogDirectory(void);

#endif
