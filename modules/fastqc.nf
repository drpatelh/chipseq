// Initialise parameters
params.outdir = './results'
params.singleEnd = false
params.skipFastQC = false

process fastqc {
    tag "$sample_id"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.endsWith(".zip") ? "zips/$filename" : "$filename"}

    when:
    !params.skipFastQC

    input:
    set val(sample_id), file(reads)

    output:
    file "*.{zip,html}"

    script:
    // Added soft-links to original fastqs for consistent naming in MultiQC
    if (params.singleEnd) {
        """
        [ ! -f  ${sample_id}.fastq.gz ] && ln -s $reads ${sample_id}.fastq.gz
        fastqc -q ${sample_id}.fastq.gz
        """
    } else {
        """
        [ ! -f  ${sample_id}_1.fastq.gz ] && ln -s ${reads[0]} ${sample_id}_1.fastq.gz
        [ ! -f  ${sample_id}_2.fastq.gz ] && ln -s ${reads[1]} ${sample_id}_2.fastq.gz
        fastqc -q ${sample_id}_1.fastq.gz
        fastqc -q ${sample_id}_2.fastq.gz
        """
    }
}
