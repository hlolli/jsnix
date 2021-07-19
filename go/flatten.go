package main

import "fmt"
import "io/ioutil"
import "io/fs"
import "log"
import "os"
import "path"
import "regexp"
import "strings"
import "syscall"
import "github.com/otiai10/copy"

var scopedModuleRe,_ = regexp.Compile(`node_modules/@([^/])*/([^/])*$`)
var stdModuleRe,_ = regexp.Compile(`node_modules/[^\.^@^/.]*$`)

func IsSyml(fi fs.FileInfo) bool {
	if fi != nil && fi.Mode() & os.ModeSymlink != 0 {
		return true
	} else {
		return false
	}
}

func IsDir(fi fs.FileInfo) bool {
	if fi.Mode().IsDir() {
		return true
	} else {
		return false
	}
}

func PathExists(filename string) bool {
	if _, err := os.Stat(filename); os.IsNotExist(err) {
		return false
	} else {
		return true
	}
}

func CanWrite(path string) bool {
	err := syscall.Access(path, syscall.O_RDWR)
	if err != nil {
		return false
	} else {
		return true
	}
}

func stringInSlice(a string, list []string) bool {
    for _, b := range list {
        if b == a {
            return true
        }
    }
    return false
}

func countMatches(s string, re *regexp.Regexp) int {
    total := 0
    for start := 0; start < len(s); {
        remaining := s[start:] // slicing the string is cheap
        loc := re.FindStringIndex(remaining)
        if loc == nil {
            break
        }
        // loc[0] is the start index of the match,
        // loc[1] is the end index (exclusive)
        start += loc[1]
        total++
    }
    return total
}


func NodeModuleDirs(root string, sys fs.FS) ([]string, []string, error) {
	var scoped []string
	var standard []string
	nodeModP := regexp.MustCompile("node_modules")


	err := fs.WalkDir(sys, root, func(path string, de fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		// nodeModPM := nodeModP.FindAllStringIndex(path, -1)
		if countMatches(path, nodeModP) > 1 && !strings.HasSuffix(path, "node_modules") {
			var scopedResult = scopedModuleRe.MatchString(path)
			if  scopedResult {
				scoped = append(scoped, path)
			}

			if stdModuleRe.MatchString(path) {
				standard = append(standard, path)
			}
		}
		return nil
	})

	return scoped, standard, err
}


func main() {
	if PathExists("node_modules") {
		var topLevelDeps []string
		topLevelDepsInfo, lsErr := ioutil.ReadDir("node_modules")
		if lsErr != nil {
			log.Fatal(lsErr)
		}

		for _, topFile := range topLevelDepsInfo {
			topLevelDeps = append(topLevelDeps, topFile.Name())
		}
		pwd, _ := os.Getwd()
		nfs := os.DirFS(pwd)
		scoped, standard, _ := NodeModuleDirs("node_modules", nfs)


		for _, stdFile := range standard {
			syminfo, _ := os.Lstat(stdFile)
			if IsSyml(syminfo) && IsDir(syminfo) {
				realPath, _ := os.Readlink(stdFile)
				os.Remove(stdFile)
				os.MkdirAll(stdFile, 0755)
				srcCpInfo, srcCpErr := ioutil.ReadDir(realPath)
				if srcCpErr != nil {
					log.Fatal(srcCpErr)
				}
				for _, cpy := range srcCpInfo {
					copy.Copy(
						cpy.Name(),
						stdFile,
						copy.Options{
							OnSymlink: func(src string) copy.SymlinkAction {
								return copy.Shallow
							},
							AddPermission: 0755,
						})
				}

			}
			dirName := path.Base(stdFile)
			if _, err := os.Stat(path.Join("./node_modules", dirName)); err == nil {
				// path exists
				if stringInSlice(dirName, topLevelDeps) {
					os.RemoveAll(stdFile)
				}

			} else if os.IsNotExist(err) {
				// path does *not* exist
				os.Rename(stdFile, path.Join("./node_modules", dirName))

			} else {
				// strangeness
				fmt.Println(err)
			}

		}
		for _, scopedFile := range scoped {
			syminfo, _ := os.Lstat(scopedFile)
			if IsSyml(syminfo) && IsDir(syminfo) {
				realPath, _ := os.Readlink(scopedFile)
				os.Remove(scopedFile)
				os.MkdirAll(scopedFile, 0755)
				srcCpInfo, srcCpErr := ioutil.ReadDir(realPath)
				if srcCpErr != nil {
					log.Fatal(srcCpErr)
				}
				for _, cpy := range srcCpInfo {
					copy.Copy(
						cpy.Name(),
						scopedFile,
						copy.Options{
							OnSymlink: func(src string) copy.SymlinkAction {
								return copy.Shallow
							},
							AddPermission: 0755,
						})
				}
			}
			dirName := path.Base(scopedFile)
			scopeName := path.Base(path.Dir(scopedFile))
			pName := path.Join(scopeName, dirName)
			os.MkdirAll(path.Join("./node_modules", scopeName), 0755)
			if _, err := os.Stat(path.Join("./node_modules", pName)); err == nil {
				// path exists
				if stringInSlice(pName, topLevelDeps) {
					os.RemoveAll(scopedFile)
				}

			} else if os.IsNotExist(err) {
				// path does *not* exist
				os.Rename(scopedFile, path.Join("./node_modules", pName))

			} else {
				// strangeness
				fmt.Println(err)
			}
		}

	} else {
		fmt.Println("no node_modules found for flattening")
	}
}
