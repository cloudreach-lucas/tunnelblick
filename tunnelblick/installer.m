/*
 * Copyright 2004, 2005, 2006, 2007, 2008, 2009 by Angelo Laub
 * Contributions by Jonathan K. Bullard Copyright 2010, 2011
 *
 *  This file is part of Tunnelblick.
 *
 *  Tunnelblick is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation.
 *
 *  Tunnelblick is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program (see the file COPYING included with this
 *  distribution); if not, write to the Free Software Foundation, Inc.,
 *  59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *  or see http://www.gnu.org/licenses/.
 */

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <AppKit/AppKit.h>
#import "defines.h"
#import "NSFileManager+TB.h"

// NOTE: THIS PROGRAM MUST BE RUN AS ROOT VIA executeAuthorized
//
// This program is called when something needs to be secured.
// It accepts two to five arguments, and always does some standard housekeeping in
// addition to the specific tasks specified by the command line arguments.
//
// Usage:
//
//     installer secureTheApp  secureAllPackages   [ targetPathToSecure   [sourcePath]  [moveFlag] ]
//
// where
//     secureTheApp      is "0", or "1" to secure this Tunnelblick.app and all of its contents
//                               or "2", to copy this app to /Applications/Tunnelblick.app and then secure the copy and its contents
//                                       (Any existing /Applications/Tunnelblick.app will be moved to the Trash)
//     secureAllPackages is "0", or "1" to secure all .tblk packages in Configurations, Shared, and the alternate configuration path
//     targetPath        is the path to a configuration (.ovpn or .conf file, or .tblk package) to be secured
//     sourcePath        is the path to be copied or moved to targetPath before securing targetPath
//     moveFlag          is "0" to copy, "1" to move
//
// It does the following:
//      (1) _Iff_ secureTheApp is "2", copies this app to /Applications
//      (2) Restores the /Deploy folder from the backup copy if it does not exist and a backup copy does,
//      (3) Moves the contents of the old configuration folder at /Library/openvpn to ~/Library/Application Support/Tunnelblick/Configurations
//      (4) Creates /Library/Application Support/Tunnelblick/Shared if it doesn't exist and makes sure it is secured
//      (5) Creates the log directory if it doesn't exist and makes sure it is secured
//      (6) _Iff_ secureTheApp is "1" or "2", secures Tunnelblick.app by setting the ownership and permissions of its components.
//      (7) _Iff_ secureTheApp is "1" or "2", makes a backup of the /Deploy folder if it exists
//      (8) _Iff_ secureAllPackages, secures all .tblk packages in the following folders:
//           /Library/Application Support/Tunnelblick/Shared
//           /Library/Application Support/Tunnelblick/Users/<username>
//           ~/Library/Application Support/Tunnelblick/Configurations
//      (9) _Iff_ sourcePath is given, copies or moves sourcePath to targetPath (copies unless moveFlag = @"1")
//     (10) _Iff_ targetPathToSecure is given, secures the .ovpn or .conf file or a .tblk package at that path
//
// When finished (or if an error occurs), the file /tmp/tunnelblick-authorized-running is deleted to indicate the program has finished
//
// Notes: (2), (3), (4), and (5) are done each time this command is invoked if they are needed (self-repair).
//        (9) is done when creating a shadow configuration file
//                    or copying a .tblk to install it
//                    or moving a .tblk to make it private or shared
//        (10) is done when repairing a shadow configuration file or after copying or moving a .tblk

NSArray       * extensionsFor600Permissions;
NSFileManager * gFileMgr;       // [NSFileManager defaultManager]
NSString      * gPrivatePath;   // Path to ~/Library/Application Support/Tunnelblick/Configurations
NSString      * gSharedPath;    // Path to /Library/Application Support/Tunnelblick/Shared
NSString      * gDeployPath;    // Path to Tunnelblick.app/Contents/Resources/Deploy
NSAutoreleasePool * pool;
uid_t realUserID;               // User ID & Group ID for the real user (i.e., not "root:wheel", which is what we are running as)
gid_t realGroupID;

BOOL checkSetOwnership(NSString * path, BOOL recurse, uid_t uid, gid_t gid);
BOOL checkSetPermissions(NSString * path, NSString * permsShouldHave, BOOL fileMustExist);
BOOL createDirWithPermissionAndOwnership(NSString * dirPath, mode_t permissions, uid_t owner, gid_t group);
BOOL createSymLink(NSString * fromPath, NSString * toPath);
void deleteFlagFile(void);
BOOL itemIsVisible(NSString * path);
BOOL secureOneFolder(NSString * path);
BOOL makeFileUnlockedAtPath(NSString * path);
BOOL moveContents(NSString * fromPath, NSString * toPath);
void errorExit();

int main(int argc, char *argv[]) 
{
	pool = [NSAutoreleasePool new];
    
    extensionsFor600Permissions = [NSArray arrayWithObjects: @"cer", @"crt", @"der", @"key", @"p12", @"p7b", @"p7c", @"pem", @"pfx", nil];
    gFileMgr = [NSFileManager defaultManager];
    gPrivatePath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tunnelblick/Configurations/"] copy];
    gSharedPath = [@"/Library/Application Support/Tunnelblick/Shared" copy];

	NSString * appResourcesPath;
    if (  (argc > 1) && (strcmp(argv[1], "2") == 0)  ) {
        appResourcesPath = @"/Applications/Tunnelblick.app/Contents/Resources";
    } else {
        appResourcesPath = [[gFileMgr stringWithFileSystemRepresentation: argv[0] length: strlen(argv[0])] stringByDeletingLastPathComponent];
    }
    
	gDeployPath                     = [appResourcesPath stringByAppendingPathComponent:@"Deploy"];
    NSString * deployBkupHolderPath = [[[[[@"/Library/Application Support/Tunnelblick/Backup" stringByAppendingPathComponent: appResourcesPath]
                                          stringByDeletingLastPathComponent]
                                         stringByDeletingLastPathComponent]
                                        stringByDeletingLastPathComponent]
                                       stringByAppendingPathComponent: @"TunnelblickBackup"];
    NSString * deployBackupPath     = [deployBkupHolderPath stringByAppendingPathComponent: @"Deploy"];
    NSString * deployOrigBackupPath = [deployBkupHolderPath stringByAppendingPathComponent: @"OriginalDeploy"];
    NSString * deployPrevBackupPath = [deployBkupHolderPath stringByAppendingPathComponent: @"PreviousDeploy"];
    
    realUserID  = getuid();
    realGroupID = getgid();
    
    BOOL isDir;
    
    if (  (argc < 3)  || (argc > 6)  ) {
        NSLog(@"Tunnelblick Installer: Wrong number of arguments -- expected 2 or 3, given %d", argc-1);
        errorExit();
    }
    
    BOOL copyApp       =  strcmp(argv[1], "2") == 0;
    BOOL secureApp     = (strcmp(argv[1], "1") == 0) || (strcmp(argv[1], "2") == 0);
    BOOL secureTblks   =  strcmp(argv[2], "1") == 0;
    
    NSString * singlePathToSecure = nil;
    if (  argc > 3  ) {
        singlePathToSecure = [gFileMgr stringWithFileSystemRepresentation: argv[3] length: strlen(argv[3])];
    }
    NSString * singlePathToCopy = nil;
    if (  argc > 4  ) {
        singlePathToCopy = [gFileMgr stringWithFileSystemRepresentation: argv[4] length: strlen(argv[4])];
    }
    BOOL moveNotCopy = FALSE;
    if (  argc > 5  ) {
        moveNotCopy = strcmp(argv[5], "1") == 0;
    }
    
    //**************************************************************************************************************************
    // (1)
    // If secureTheApp = "2", move /Applications/Tunnelblick.app to the Trash, then copy this app to /Applications/Tunnelblick.app
    
    if (  copyApp  ) {
        NSString * currentPath = [[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString * targetPath = @"/Applications/Tunnelblick.app";
        if (  [gFileMgr fileExistsAtPath: targetPath]  ) {
            if (  [[NSWorkspace sharedWorkspace] performFileOperation: NSWorkspaceRecycleOperation
                                                               source: @"/Applications"
                                                          destination: @""
                                                                files: [NSArray arrayWithObject:@"Tunnelblick.app"]
                                                                  tag: nil]  ) {
                NSLog(@"Tunnelblick Installer: Moved %@ to the Trash", targetPath);
            } else {
                NSLog(@"Tunnelblick Installer: Unable to move %@ to the Trash", targetPath);
                errorExit();
            }
        }
        
        if (  ! [gFileMgr tbCopyPath: currentPath toPath: targetPath handler: nil]  ) {
            NSLog(@"Tunnelblick Installer: Unable to copy %@ to %@", currentPath, targetPath);
            errorExit();
        } else {
            NSLog(@"Tunnelblick Installer: Copied %@ to %@", currentPath, targetPath);
        }
    }
        
    //**************************************************************************************************************************
    // (2)
    // If Resources/Deploy does not exist, but a backup of it does exist (happens when Tunnelblick.app has been updated)
    // Then restore it from the backup
    if (   [gFileMgr fileExistsAtPath: deployBackupPath isDirectory: &isDir]
        && isDir  ) {
        if (  ! (   [gFileMgr fileExistsAtPath: gDeployPath isDirectory: &isDir]
                 && isDir  )  ) {
            if (  ! [gFileMgr tbCopyPath: deployBackupPath toPath: gDeployPath handler: nil]  ) {
                NSLog(@"Tunnelblick Installer: Unable to restore %@ from backup", gDeployPath);
                errorExit();
            }

            NSLog(@"Tunnelblick Installer: Restored %@ from backup", gDeployPath);
        }
    }
    
    //**************************************************************************************************************************
    // (3)
    // Deal with migration to new configuration path
    NSString * oldConfigDirPath = [NSHomeDirectory() stringByAppendingPathComponent: @"Library/openvpn"];
    NSString * newConfigDirPath = [NSHomeDirectory() stringByAppendingPathComponent: @"Library/Application Support/Tunnelblick/Configurations"];
    
    // Verify that new configuration folder exists
    if (  ! [gFileMgr fileExistsAtPath: newConfigDirPath isDirectory: &isDir]  ) {
        NSLog(@"Tunnelblick Installer: Private configuration folder %@ does not exist", newConfigDirPath);
        errorExit();
    } else if (  ! isDir  ) {
        NSLog(@"Tunnelblick Installer: %@ exists but is not a folder", newConfigDirPath);
        errorExit();
    }
    
    // If old configurations folder exists (and is a folder):
    // Move its contents to the new configurations folder and delete it
    NSDictionary * fileAttributes = [gFileMgr tbFileAttributesAtPath: oldConfigDirPath traverseLink: NO];
    if (  ! [[fileAttributes objectForKey: NSFileType] isEqualToString: NSFileTypeSymbolicLink]  ) {
        if (  [gFileMgr fileExistsAtPath: oldConfigDirPath isDirectory: &isDir]  ) {
            if (  isDir  ) {
                // Move old configurations folder's contents to the new configurations folder and delete the old folder
                if (  moveContents(oldConfigDirPath, newConfigDirPath)  ) {
                    NSLog(@"Tunnelblick Installer: Moved contents of %@ to %@", oldConfigDirPath, newConfigDirPath);
                    secureTblks = TRUE; // We may have moved some .tblks, so we should secure them
                    // Delete the old configuration folder
                    if (  ! [gFileMgr tbRemoveFileAtPath:oldConfigDirPath handler: nil]  ) {
                        NSLog(@"Tunnelblick Installer: Unable to remove %@", oldConfigDirPath);
                        errorExit();
                    }
                } else {
                    NSLog(@"Tunnelblick Installer: Unable to move all contents of %@ to %@", oldConfigDirPath, newConfigDirPath);
                    errorExit();
                }
            } else {
                NSLog(@"Tunnelblick Installer: %@ is not a symbolic link or a folder", oldConfigDirPath);
                errorExit();
            }
        }
    }

    //**************************************************************************************************************************
    // (4)
    // Create /Library/Application Support/Tunnelblick/Shared if it does not already exist, and make sure it is owned by root with 755 permissions
    
    if (  ! createDirWithPermissionAndOwnership(gSharedPath, 0755, 0, 0)  ) {
        errorExit();
    }
    
    //**************************************************************************************************************************
    // (5)
    // Create log directory if it does not already exist, and make sure it is owned by root with 755 permissions
    
    if (  ! createDirWithPermissionAndOwnership(LOG_DIR, 0755, 0, 0)  ) {
        errorExit();
    }
    
    //**************************************************************************************************************************
    // (6)
    // If requested, secure Tunnelblick.app by setting ownership of Info.plist and Resources and its contents to root:wheel,
    // and setting permissions as follows:
    //        Info.plist is set to 0644
    //        openvpnstart is set to 04555 (SUID)
    //        openvpn is set to 0755
    //        Other executables and standard scripts are set to 0744
    //        For the contents of /Resources/Deploy and its subfolders:
    //            folders are set to 0755
    //            certificate & key files (various extensions) are set to 0600
    //            shell scripts (*.sh) are set to 0744
    //            all other files are set to 0644
    if ( secureApp ) {
        
        NSString *installerPath         = [appResourcesPath stringByAppendingPathComponent:@"installer"];
        NSString *openvpnstartPath      = [appResourcesPath stringByAppendingPathComponent:@"openvpnstart"];
        NSString *openvpnPath           = [appResourcesPath stringByAppendingPathComponent:@"openvpn"];
        NSString *atsystemstartPath     = [appResourcesPath stringByAppendingPathComponent:@"atsystemstart"];
        NSString *leasewatchPath        = [appResourcesPath stringByAppendingPathComponent:@"leasewatch"];
        NSString *clientUpPath          = [appResourcesPath stringByAppendingPathComponent:@"client.up.osx.sh"];
        NSString *clientDownPath        = [appResourcesPath stringByAppendingPathComponent:@"client.down.osx.sh"];
        NSString *clientNoMonUpPath     = [appResourcesPath stringByAppendingPathComponent:@"client.nomonitor.up.osx.sh"];
        NSString *clientNoMonDownPath   = [appResourcesPath stringByAppendingPathComponent:@"client.nomonitor.down.osx.sh"];
        NSString *infoPlistPath         = [[appResourcesPath stringByDeletingLastPathComponent] stringByAppendingPathComponent: @"Info.plist"];
        NSString *clientNewUpPath       = [appResourcesPath stringByAppendingPathComponent:@"client.up.tunnelblick.sh"];
        NSString *clientNewDownPath     = [appResourcesPath stringByAppendingPathComponent:@"client.down.tunnelblick.sh"];
        NSString *clientNewAlt1UpPath   = [appResourcesPath stringByAppendingPathComponent:@"client.1.up.tunnelblick.sh"];
        NSString *clientNewAlt1DownPath = [appResourcesPath stringByAppendingPathComponent:@"client.1.down.tunnelblick.sh"];
        NSString *clientNewAlt2UpPath   = [appResourcesPath stringByAppendingPathComponent:@"client.2.up.tunnelblick.sh"];
        NSString *clientNewAlt2DownPath = [appResourcesPath stringByAppendingPathComponent:@"client.2.down.tunnelblick.sh"];
        
        BOOL okSoFar = YES;
        okSoFar = okSoFar && checkSetOwnership(infoPlistPath, NO, 0, 0);
        
        okSoFar = okSoFar && checkSetOwnership(appResourcesPath, YES, 0, 0);
        
        okSoFar = okSoFar && checkSetPermissions(openvpnstartPath,     @"4555", YES);
        
        okSoFar = okSoFar && checkSetPermissions(infoPlistPath,         @"644", YES);
        
        okSoFar = okSoFar && checkSetPermissions(openvpnPath,           @"755", YES);
        okSoFar = okSoFar && checkSetPermissions(installerPath,         @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(atsystemstartPath,     @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(leasewatchPath,        @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientUpPath,          @"744", NO);
        okSoFar = okSoFar && checkSetPermissions(clientDownPath,        @"744", NO);
        okSoFar = okSoFar && checkSetPermissions(clientNoMonUpPath,     @"744", NO);
        okSoFar = okSoFar && checkSetPermissions(clientNoMonDownPath,   @"744", NO);
        okSoFar = okSoFar && checkSetPermissions(clientNewUpPath,       @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientNewDownPath,     @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientNewAlt1UpPath,   @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientNewAlt1DownPath, @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientNewAlt2UpPath,   @"744", YES);
        okSoFar = okSoFar && checkSetPermissions(clientNewAlt2DownPath, @"744", YES);
        
        if (   [gFileMgr fileExistsAtPath: gDeployPath isDirectory: &isDir]
            && isDir  ) {
            okSoFar = okSoFar && checkSetPermissions(gDeployPath,       @"755", YES);
            okSoFar = okSoFar && secureOneFolder(gDeployPath);
        }
        
        if (  ! okSoFar  ) {
            NSLog(@"Tunnelblick Installer: Unable to secure Tunnelblick.app");
            errorExit();
        }
    }
    
    //**************************************************************************************************************************
    // (7)
    // If Resources/Deploy exists, back it up -- saving the first configuration and the two most recent
    if ( secureApp ) {
        
        if (   [gFileMgr fileExistsAtPath: gDeployPath isDirectory: &isDir]
            && isDir  ) {
            
            // Create the folder that holds the backup folders if it doesn't already exist
            if (  ! createDirWithPermissionAndOwnership(deployBkupHolderPath, 0755, 0, 0)  ) {
                errorExit();
            }
            
            if (  ! (   [gFileMgr fileExistsAtPath: deployOrigBackupPath isDirectory: &isDir]
                     && isDir  )  ) {
                if (  ! [gFileMgr tbCopyPath: gDeployPath toPath: deployOrigBackupPath handler: nil]  ) {
                    NSLog(@"Tunnelblick Installer: Unable to make original backup of %@", gDeployPath);
                    errorExit();
                }
            }
            
            [gFileMgr tbRemoveFileAtPath:deployPrevBackupPath handler: nil];                       // Make original backup. Ignore errors -- original backup may not exist yet
            [gFileMgr tbMovePath: deployBackupPath toPath: deployPrevBackupPath handler: nil];    // Make backup of previous backup. Ignore errors -- previous backup may not exist yet
            
            if (  ! [gFileMgr tbCopyPath: gDeployPath toPath: deployBackupPath handler: nil]  ) {  // Make backup of current
                NSLog(@"Tunnelblick Installer: Unable to make backup of %@", gDeployPath);
                errorExit();
            }
        }
    }
        
    //**************************************************************************************************************************
    // (8)
    // If requested, secure all .tblk packages
    if (  secureTblks  ) {
        NSString * sharedPath  = @"/Library/Application Support/Tunnelblick/Shared";
        NSString * libraryPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tunnelblick/Configurations/"];
        NSString * altPath     = [NSString stringWithFormat:@"/Library/Application Support/Tunnelblick/Users/%@", NSUserName()];
        
        NSArray * foldersToSecure = [NSArray arrayWithObjects: libraryPath, sharedPath, altPath, nil];
        
        BOOL okSoFar = YES;
        int i;
        for (i=0; i < [foldersToSecure count]; i++) {
            NSString * folderPath = [foldersToSecure objectAtIndex: i];
            NSString * file;
            NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: folderPath];
            while (  file = [dirEnum nextObject]  ) {
                NSString * filePath = [folderPath stringByAppendingPathComponent: file];
                if (  itemIsVisible(filePath)  ) {
                    if (   [gFileMgr fileExistsAtPath: filePath isDirectory: &isDir]
                        && isDir
                        && [[file pathExtension] isEqualToString: @"tblk"]  ) {
                        if (  [filePath hasPrefix: gPrivatePath]  ) {
                            okSoFar = okSoFar && checkSetOwnership(filePath, NO, realUserID, realGroupID);
                        } else {
                            okSoFar = okSoFar && checkSetOwnership(filePath, NO, 0, 0);
                        }
                        okSoFar = okSoFar && checkSetPermissions(filePath, @"755", YES);
                        okSoFar = okSoFar && secureOneFolder(filePath);
                    }
                }
            }
        }
        
        if (  ! okSoFar  ) {
            NSLog(@"Tunnelblick Installer: Warning: Unable to secure all .tblk packages");
        }
    }
    
    //**************************************************************************************************************************
    // (9)
    // If requested, copy or move a single file or .tblk package
    // Like the NSFileManager "movePath:toPath:handler" method, we move by copying, then deleting, because we may be moving
    // from one disk to another (e.g., home folder on network to local hard drive)
    if (  singlePathToCopy  ) {
        // Create the enclosing folder(s) if necessary. Owned by root unless if in gPrivatePath, in which case it is owned by the user
        NSString * enclosingFolder = [singlePathToSecure stringByDeletingLastPathComponent];
        uid_t own = 0;
        gid_t grp = 0;
        if (  [singlePathToSecure hasPrefix: gPrivatePath]  ) {
            own = realUserID;
            grp = realGroupID;
        }
        
        if (  ! createDirWithPermissionAndOwnership(enclosingFolder, 0755, own, grp)  ) {
            errorExit();
        }
        
        // Copy the file or package to a ".partial" file/folder first, then rename it
        // This avoids a race condition: folder change handling code runs while copy is being made, so it sometimes can
        // see the .tblk (which has been copied) but not the config.ovpn (which hasn't been copied yet), so it complains.
        NSString * dotPartialPath = [singlePathToSecure stringByAppendingPathExtension: @"partial"];
        [gFileMgr tbRemoveFileAtPath:dotPartialPath handler: nil];
        if (  ! [gFileMgr tbCopyPath: singlePathToCopy toPath: dotPartialPath handler: nil]  ) {
            NSLog(@"Tunnelblick Installer: Failed to copy %@ to %@", singlePathToCopy, dotPartialPath);
            [gFileMgr tbRemoveFileAtPath:dotPartialPath handler: nil];
            errorExit();
        }
        
        BOOL errorHappened = FALSE; // Use this to defer error exit until after renaming xxx.partial to xxx
        
        // Now, if we are doing a move, delete the original file, to avoid a similar race condition that will cause a complaint
        // about duplicate configuration names.
        if (  moveNotCopy  ) {
            if (  ! [gFileMgr tbRemoveFileAtPath:singlePathToCopy handler: nil]  ) {
                NSLog(@"Tunnelblick Installer: Failed to delete %@", singlePathToCopy);
                errorHappened = TRUE;
            }
        }

        [gFileMgr tbRemoveFileAtPath:singlePathToSecure handler: nil];
        if (  ! [gFileMgr tbMovePath: dotPartialPath toPath: singlePathToSecure handler: nil]  ) {
            NSLog(@"Tunnelblick Installer: Failed to rename %@ to %@", dotPartialPath, singlePathToSecure);
            [gFileMgr tbRemoveFileAtPath:dotPartialPath handler: nil];
            errorExit();
        }
        
        if (  errorHappened  ) {
            errorExit();
        }

        if (  ! makeFileUnlockedAtPath(singlePathToSecure)  ) {
            errorExit();
        }
    }
    
    //**************************************************************************************************************************
    // (10)
    // If requested, secure a single file or .tblk package
    if (  singlePathToSecure  ) {
        BOOL okSoFar = TRUE;
        NSString * ext = [singlePathToSecure pathExtension];
        if (  [ext isEqualToString: @"ovpn"] || [ext isEqualToString: @"conf"]  ) {
            okSoFar = okSoFar && checkSetOwnership(singlePathToSecure, NO, 0, 0);
            okSoFar = okSoFar && checkSetPermissions(singlePathToSecure, @"644", YES);
        } else if (  [ext isEqualToString: @"tblk"]  ) {
            if (  [singlePathToSecure hasPrefix: gPrivatePath]  ) {
                okSoFar = okSoFar && checkSetOwnership(singlePathToSecure, NO, realUserID, realGroupID);
            } else {
                okSoFar = okSoFar && checkSetOwnership(singlePathToSecure, YES, 0, 0);
            }
            okSoFar = okSoFar && checkSetPermissions(singlePathToSecure, @"755", YES);
            okSoFar = okSoFar && secureOneFolder(singlePathToSecure);
        } else {
            NSLog(@"Tunnelblick Installer: trying to secure unknown item at %@", singlePathToSecure);
            errorExit();
        }
        if (  ! okSoFar  ) {
            NSLog(@"Tunnelblick Installer: unable to secure %@", singlePathToSecure);
            errorExit();
        }
    }
    
    deleteFlagFile();
    
    [pool release];
    exit(EXIT_SUCCESS);
}

//**************************************************************************************************************************

void deleteFlagFile(void)
{
    char * path = "/tmp/tunnelblick-authorized-running";
    struct stat sb;
	if (  0 == stat(path, &sb)  ) {
        if (  (sb.st_mode & S_IFMT) == S_IFREG  ) {
            if (  0 != unlink(path)  ) {
                NSLog(@"Tunnelblick Installer: Unable to delete %s", path);
            }
        } else {
            NSLog(@"Tunnelblick Installer: %s is not a regular file; st_mode = 0%o", path, sb.st_mode);
        }
    } else {
        NSLog(@"Tunnelblick Installer: stat of %s failed\nError was '%s'", path, strerror(errno));
    }
}

//**************************************************************************************************************************
void errorExit()
{
    deleteFlagFile();

    [pool release];
    exit(EXIT_FAILURE);
}

//**************************************************************************************************************************
BOOL moveContents(NSString * fromPath, NSString * toPath)
{
    NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: fromPath];
    NSString * file;
    while (  file = [dirEnum nextObject]  ) {
        [dirEnum skipDescendents];
        if (  ! [file hasPrefix: @"."]  ) {
            NSString * fullFromPath = [fromPath stringByAppendingPathComponent: file];
            NSString * fullToPath   = [toPath   stringByAppendingPathComponent: file];
            if (  [gFileMgr fileExistsAtPath: fullToPath]  ) {
                NSLog(@"Tunnelblick Installer: Unable to move %@ to %@ because the destination already exists", fullFromPath, fullToPath);
                return NO;
            } else {
                if (  ! [gFileMgr tbMovePath: fullFromPath toPath: fullToPath handler: nil]  ) {
                    NSLog(@"Tunnelblick Installer: Unable to move %@ to %@", fullFromPath, fullToPath);
                    return NO;
                }
            }
        }
    }
    
    return YES;
}

//**************************************************************************************************************************
BOOL createSymLink(NSString * fromPath, NSString * toPath)
{
    if (  [gFileMgr tbCreateSymbolicLinkAtPath: fromPath pathContent: toPath]  ) {
        // Since we're running as root, owner of symbolic link is root:wheel. Try to change to real user:group
        if (  0 != lchown([gFileMgr fileSystemRepresentationWithPath: fromPath], realUserID, realGroupID)  ) {
            NSLog(@"Tunnelblick Installer: Error: Unable to change ownership of symbolic link %@\nError was '%s'", fromPath, strerror(errno));
            return NO;
        } else {
            NSLog(@"Tunnelblick Installer: Successfully created a symbolic link from %@ to %@", fromPath, toPath);
            return YES;
        }
    }

    NSLog(@"Tunnelblick Installer: Error: Unable to create symbolic link from %@ to %@", fromPath, toPath);
    return NO;
}

//**************************************************************************************************************************
BOOL makeFileUnlockedAtPath(NSString * path)
{
    // Make sure the copy is unlocked
    NSDictionary * curAttributes;
    NSDictionary * newAttributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithInt:0] forKey: NSFileImmutable];
    
    int i;
    int maxTries = 5;
    for (i=0; i <= maxTries; i++) {
        curAttributes = [gFileMgr tbFileAttributesAtPath: path traverseLink:YES];
        if (  ! [curAttributes fileIsImmutable]  ) {
            break;
        }
        [gFileMgr tbChangeFileAttributes: newAttributes atPath: path];
        sleep(1);
    }
    
    if (  [curAttributes fileIsImmutable]  ) {
        NSLog(@"Tunnelblick Installer: Failed to unlock configuration %@ in %d attempts", path, maxTries);
        return FALSE;
    }
    return TRUE;
}

//**************************************************************************************************************************
// Changes ownership of a file or folder if necessary to the specified user/group.
// If "recurse" is TRUE, also changes ownership on all contents of a folder (except invisible items)
// Returns YES on success, NO on failure
BOOL checkSetOwnership(NSString * path, BOOL recurse, uid_t uid, gid_t gid)
{
    NSDictionary * atts = [[NSFileManager defaultManager] tbFileAttributesAtPath: path traverseLink: YES];
    if (   [[atts fileOwnerAccountID]      isEqualToNumber: [NSNumber numberWithInt: uid]]
        && [[atts fileGroupOwnerAccountID] isEqualToNumber: [NSNumber numberWithInt: gid]]  ) {
        return YES;
    }
    
    if (  [atts fileIsImmutable]  ) {
        NSLog(@"Tunnelblick Installer: Unable to change ownership because item is locked: %@", path);
        return NO;
    }
    
    if (  chown([gFileMgr fileSystemRepresentationWithPath: path], uid, gid) != 0  ) {
        NSLog(@"Tunnelblick Installer: Unable to change ownership to %d:%d on %@\nError was '%s'", (int) uid, (int) gid, path, strerror(errno));
        return NO;
    }
    
    NSString * recurseNote = @"";
    
    if (  recurse  ) {
        recurseNote = @" and its contents";
        NSString * file;
        NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: path];
        while ( file = [dirEnum nextObject]  ) {
            if (  itemIsVisible(file)  ) {
                NSString * filePath = [path stringByAppendingPathComponent: file];
                atts = [[NSFileManager defaultManager] tbFileAttributesAtPath: filePath traverseLink: YES];
                if (   ! [[atts fileOwnerAccountID]      isEqualToNumber: [NSNumber numberWithInt: uid]]
                    || ! [[atts fileGroupOwnerAccountID] isEqualToNumber: [NSNumber numberWithInt: gid]]  ) {
                    if (  chown([gFileMgr fileSystemRepresentationWithPath: filePath], uid, gid) != 0  ) {
                        NSLog(@"Tunnelblick Installer: Unable to change ownership to %d:%d on %@\nError was '%s'", (int) uid, (int) gid, filePath, strerror(errno));
                        return NO;
                    }
                }
            }
        }
    }
    
    NSLog(@"Tunnelblick Installer: Changed ownership to %d:%d on %@%@", (int) uid, (int) gid,  path, recurseNote);
    return YES;
}

//**************************************************************************************************************************
// Changes permissions on a file or folder (but not the folder's contents) to specified values if necessary
// Returns YES on success, NO on failure
// Also returns YES if no such file or folder and 'fileMustExist' is FALSE
BOOL checkSetPermissions(NSString * path, NSString * permsShouldHave, BOOL fileMustExist)
{
    if (  ! [gFileMgr fileExistsAtPath: path]  ) {
        if (  fileMustExist  ) {
            return NO;
        }
        return YES;
    }

    NSDictionary *atts = [gFileMgr tbFileAttributesAtPath: path traverseLink:YES];
    unsigned long perms = [atts filePosixPermissions];
    NSString *octalPerms = [NSString stringWithFormat:@"%o",perms];
    
    if (   [octalPerms isEqualToString: permsShouldHave]  ) {
        return YES;
    }
    
    if (  [atts fileIsImmutable]  ) {
        NSLog(@"Tunnelblick Installer: Cannot change permissions because item is locked: %@", path);
        return NO;
    }
    
    mode_t permsMode;
    if      (  [permsShouldHave isEqualToString:  @"755"]  ) permsMode =  0755;
    else if (  [permsShouldHave isEqualToString:  @"744"]  ) permsMode =  0744;
    else if (  [permsShouldHave isEqualToString:  @"644"]  ) permsMode =  0644;
    else if (  [permsShouldHave isEqualToString:  @"600"]  ) permsMode =  0600;
    else if (  [permsShouldHave isEqualToString: @"4555"]  ) permsMode = 04555;
    else {
        NSLog(@"Tunnelblick Installer: invalid permsShouldHave = '%@' in checkSetPermissions function", permsShouldHave);
        return NO;
    }
    
    if (  chmod([gFileMgr fileSystemRepresentationWithPath: path], permsMode) != 0  ) {
        NSLog(@"Tunnelblick Installer: Unable to change permissions to 0%@ on %@", permsShouldHave, path);
        return NO;
    }

    NSLog(@"Tunnelblick Installer: Changed permissions to 0%@ on %@", permsShouldHave, path);
    return YES;
}

//**************************************************************************************************************************
// Function to create a directory with specified ownership and permissions
// Recursively creates all intermediate directories (with the same ownership and permissions) as needed
// Returns YES if the directory existed with the specified ownership and permissions or has been created with them
BOOL createDirWithPermissionAndOwnership(NSString * dirPath, mode_t permissions, uid_t owner, gid_t group)
{
    // Don't try to create or set ownership or permissions on
    //       /Library/Application Support
    //   or ~/Library/Application Support
    if (  [dirPath hasSuffix: @"/Library/Application Support"]  ) {
        return YES;
    }
    
    BOOL isDir;
    
    if (  ! (   [gFileMgr fileExistsAtPath: dirPath isDirectory: &isDir]
             && isDir )  ) {
        // No such directory. Create its parent directory if necessary
        NSString * parentPath = [dirPath stringByDeletingLastPathComponent];
        if (  ! createDirWithPermissionAndOwnership(parentPath, permissions, owner, group)  ) {
            return NO;
        }
        
        // Parent directory exists. Create the directory we want
        if (  mkdir([gFileMgr fileSystemRepresentationWithPath: dirPath], (mode_t) permissions) != 0  ) {
            NSLog(@"Tunnelblick Installer: Unable to create directory %@", dirPath);
            return NO;
        }

        NSLog(@"Tunnelblick Installer: Created directory %@", dirPath);
    }

    
    // Directory exists. Check/set ownership and permissions
    if (  ! checkSetOwnership(dirPath, NO, owner, group)  ) {
        return NO;
    }
    NSString * permissionsAsString = [NSString stringWithFormat: @"%o", (int) permissions];
    if (  ! checkSetPermissions(dirPath, permissionsAsString, YES)  ) {
        return NO;
    }
    
    return YES;
}

//**************************************************************************************************************************
// Returns YES if path to an item has no components starting with a period
BOOL itemIsVisible(NSString * path)
{
    if (  [path hasPrefix: @"."]  ) {
        return NO;
    }
    NSRange rng = [path rangeOfString:@"/."];
    if (  rng.length != 0) {
        return NO;
    }
    return YES;
}

//**************************************************************************************************************************
// Makes sure that ownership/permissions of the CONTENTS of a specified folder (either /Deploy or a .tblk package) are secure
// If necessary, changes ownership on all *contents* of of the folder to root:wheel, except /Contents/Resources folders and .tblk folders
// in the ~/Library/.../Configurations folder are changed to be owned by the user so the user can edit the configuration file
// If necessary, changes permissions on *contents* of the folder as follows
//         invisible files (those with _any_ path component that starts with a period) are not changed
//         folders and executables are set to 755
//         shell scripts are set to 744
//         certificate & key files are set to 600
//         all other visible files are set to 644
// DOES NOT change ownership or permissions on the folder itself
// Returns YES if successfully secured everything, otherwise returns NO
BOOL secureOneFolder(NSString * path)
{
    BOOL result = YES;
    BOOL isDir;
    NSString * file;
    NSFileManager * gFileMgr = [NSFileManager defaultManager];
    NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: path];
    while (file = [dirEnum nextObject]) {
        NSString * filePath = [path stringByAppendingPathComponent: file];
        if (  itemIsVisible(filePath)  ) {
            NSString * ext  = [file pathExtension];
            if (   [filePath hasSuffix: @".tblk/Contents/Resources"]
                || [ext isEqualToString: @"tblk"]  ) {
                if (  [filePath hasPrefix: gPrivatePath]  ) {
                    result = result && checkSetOwnership(filePath, NO, realUserID, realGroupID);
                } else {
                    result = result && checkSetOwnership(filePath, NO, 0, 0);
                }
            } else {
                result = result && checkSetOwnership(filePath, NO, 0, 0);
            }
            if (   [gFileMgr fileExistsAtPath: filePath isDirectory: &isDir]
                && isDir  ) {
                result = result && checkSetPermissions(filePath, @"755", YES);           // Folders are 755
            } else if ( [ext isEqualToString:@"executable"]  ) {
                result = result && checkSetPermissions(filePath, @"755", YES);           // executable files for custom menu commands are 755
            } else if ( [ext isEqualToString:@"sh"]  ) {
                result = result && checkSetPermissions(filePath, @"744", YES);           // Scripts are 744
            } else if (  [extensionsFor600Permissions containsObject: ext]  ) {
                result = result && checkSetPermissions(filePath, @"600", YES);           // Keys and certificates are 600
            } else {
                result = result && checkSetPermissions(filePath, @"644", YES);           // Everything else is 644
            }
        }
    }
    
    return result;
}
