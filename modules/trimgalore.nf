// Initialise parameters
params.outdir = './results'
params.singleEnd = false
params.clip_r1 = 0
params.clip_r2 = 0
params.three_prime_clip_r1 = 0
params.three_prime_clip_r2 = 0
params.skipTrimming = false

process trimgalore {
    tag "$sample_id"
    //label 'process_long'
    publishDir "${params.outdir}/trim_galore", mode: 'copy',
        saveAs: {filename ->
            if (filename.endsWith(".html")) "fastqc/$filename"
            else if (filename.endsWith(".zip")) "fastqc/zips/$filename"
            else if (filename.endsWith("trimming_report.txt")) "logs/$filename"
            else params.saveTrimmed ? filename : null
        }

    when:
    !params.skipTrimming

    input:
    set val(sample_id), file(reads)

    output:
    set val(sample_id), file("*.fq.gz")
    file "*.txt"
    file "*.{zip,html}"

    script:
    // Added soft-links to original fastqs for consistent naming in MultiQC
    c_r1 = params.clip_r1 > 0 ? "--clip_r1 ${params.clip_r1}" : ''
    c_r2 = params.clip_r2 > 0 ? "--clip_r2 ${params.clip_r2}" : ''
    tpc_r1 = params.three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${params.three_prime_clip_r1}" : ''
    tpc_r2 = params.three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${params.three_prime_clip_r2}" : ''
    if (params.singleEnd) {
        """
        [ ! -f  ${sample_id}.fastq.gz ] && ln -s $reads ${sample_id}.fastq.gz
        trim_galore --fastqc --gzip $c_r1 $tpc_r1 ${sample_id}.fastq.gz
        """
    } else {
        """
        [ ! -f  ${sample_id}_1.fastq.gz ] && ln -s ${reads[0]} ${sample_id}_1.fastq.gz
        [ ! -f  ${sample_id}_2.fastq.gz ] && ln -s ${reads[1]} ${sample_id}_2.fastq.gz
        trim_galore --paired --fastqc --gzip $c_r1 $c_r2 $tpc_r1 $tpc_r2 ${sample_id}_1.fastq.gz ${sample_id}_2.fastq.gz
        """
    }
}
