package community.reel.core

import java.io.File
import java.nio.file.Files

/** A fresh folder and memory-backed settings for every test. */
fun freshPlatform(): File {
    val folder = Files.createTempDirectory("reel-test").toFile()
    Platform.setUpForTests(folder)
    return folder
}
