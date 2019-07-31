#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/chipseq
========================================================================================
 nf-core/chipseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/chipseq
----------------------------------------------------------------------------------------
*/

nextflow.preview.dsl = 2

/*
 * Check/set parameters
 */
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}
params.fasta = params.genomes[params.genome]?.fasta
params.bwa_index = params.genomes[params.genome]?.bwa
params.gtf = params.genomes[params.genome]?.gtf
params.gene_bed = params.genomes[params.genome]?.gene_bed
params.macs_gsize = params.genomes[params.genome]?.macs_gsize
params.blacklist = params.genomes[params.genome]?.blacklist

/*
 * Create channels for pipeline-specific config files
 */
ch_peak_count_header = file("$baseDir/assets/multiqc/peak_count_header.txt", checkIfExists: true)
ch_frip_score_header = file("$baseDir/assets/multiqc/frip_score_header.txt", checkIfExists: true)
ch_peak_annotation_header = file("$baseDir/assets/multiqc/peak_annotation_header.txt", checkIfExists: true)
ch_deseq2_pca_header = file("$baseDir/assets/multiqc/deseq2_pca_header.txt", checkIfExists: true)
ch_deseq2_clustering_header = file("$baseDir/assets/multiqc/deseq2_clustering_header.txt", checkIfExists: true)
ch_spp_correlation_header = file("$baseDir/assets/multiqc/spp_correlation_header.txt", checkIfExists: true)
ch_spp_nsc_header = file("$baseDir/assets/multiqc/spp_nsc_header.txt", checkIfExists: true)
ch_spp_rsc_header = file("$baseDir/assets/multiqc/spp_rsc_header.txt", checkIfExists: true)

/*
 * Has the run name been specified by the user?
 * This has the bonus effect of catching both -name and --name
 */
params.run_name = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)){
    params.run_name = workflow.runName
}

/*
 * Print help message if required
 */
if (params.help) {
    include print_help from 'modules/pipeline_params' params(params)
    print_help()
    exit 0
}

/*
 * Print parameter summary
 */
include create_summary from 'modules/pipeline_params' params(params)
summary = create_summary()

/*
 * Check the hostnames against configured profiles
 */
include 'modules/check_hostname' params(params)
check_hostname()

/*
 * PREPROCESSING - Reformat design file, check validity and create IP vs control mappings
 */
if (params.design) { ch_design = file(params.design, checkIfExists: true) } else { exit 1, "Samples design file not specified!" }
include 'modules/check_design' params(params)
check_design(ch_design)

// Create channels for input fastq files
if (params.singleEnd) {
    check_design.out
                .first()
                .splitCsv(header:true, sep:',')
                .map { row -> [ row.sample_id, [ file(row.fastq_1, checkIfExists: true) ] ] }
                .set { ch_raw_reads }
} else {
    check_design.out
                .first()
                .splitCsv(header:true, sep:',')
                .map { row -> [ row.sample_id, [ file(row.fastq_1, checkIfExists: true), file(row.fastq_2, checkIfExists: true) ] ] }
                .set { ch_raw_reads }
}

// Create a channel with [sample_id, control id, antibody, replicatesExist, multipleGroups]
check_design.out
            .last()
            .splitCsv(header:true, sep:',')
            .map { row -> [ row.sample_id, row.control_id, row.antibody, row.replicatesExist.toBoolean(), row.multipleGroups.toBoolean() ] }
            .set { ch_design_controls }

/*
 * PREPROCESSING - Build BWA index
 */
if (params.fasta) {
    lastPath = params.fasta.lastIndexOf(File.separator)
    bwa_base = params.fasta.substring(lastPath+1)
    ch_fasta = file(params.fasta, checkIfExists: true)
} else {
    exit 1, "Fasta file not specified!"
}

if (params.bwa_index) {
    lastPath = params.bwa_index.lastIndexOf(File.separator)
    bwa_dir =  params.bwa_index.substring(0,lastPath+1)
    bwa_base = params.bwa_index.substring(lastPath+1)
    Channel
        .fromPath(bwa_dir, checkIfExists: true)
        .ifEmpty { exit 1, "BWA index directory not found: ${bwa_dir}" }
        .set{ ch_bwa_index }
} else {
    include 'modules/bwa_index' params(params)
    bwa_index(ch_fasta).set { ch_bwa_index }
}

/*
 * PREPROCESSING - Generate gene BED file
 */
if (params.gtf) { ch_gtf = file(params.gtf, checkIfExists: true) } else { exit 1, "GTF annotation file not specified!" }
if (params.gene_bed) {
    ch_gene_bed = file(params.gene.bed, checkIfExists: true)
} else {
    include 'modules/gtf_to_bed' params(params)
    gtf_to_bed(ch_gtf).set { ch_gene_bed }
}

/*
 * PREPROCESSING - Generate TSS BED file
 */
if (params.tss_bed) {
    ch_tss_bed = file(params.tss_bed, checkIfExists: true)
} else {
    include 'modules/gene_to_tss_bed' params(params)
    gene_to_tss_bed(ch_gene_bed).set { ch_tss_bed }
}

/*
 * PREPROCESSING - Prepare genome intervals for filtering
 */
if (params.blacklist) { ch_blacklist = file(params.blacklist, checkIfExists: true) }
if (params.singleEnd) {
    ch_bamtools_filter_config = file(params.bamtools_filter_se_config, checkIfExists: true)
} else {
    ch_bamtools_filter_config = file(params.bamtools_filter_pe_config, checkIfExists: true)
}
include 'modules/genome_filter' params(params)
genome_filter(ch_fasta)


/*
 * STEP 1 - FastQC
 */
include 'modules/fastqc' params(params)
fastqc(ch_raw_reads)

/*
 * STEP 2 - Trim Galore!
 */
 include 'modules/trimgalore' params(params)
 trimgalore(ch_raw_reads)





/*
 * Get software versions
 */
include 'modules/get_software_versions' params(params)
get_software_versions()

/*
 * MultiQC
 */

// Create workflow summary for MultiQC
include 'modules/multiqc_workflow_summary'
multiqc_workflow_summary(summary)

ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)


/*
 * Output markdown documentation
 */
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)
include 'modules/output_docs' params(params)
output_docs(ch_output_docs)

// /*
//  * Send completion email
//  */
// workflow.onComplete {
//     include 'modules/send_email' params(params)
//     send_email(summary)
// }

// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                        ALIGN                                        -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// /*
//  * STEP 3.1 - Align read 1 with bwa
//  */
// process bwaMEM {
//     tag "$name"
//     label 'process_high'
//
//     input:
//     set val(name), file(reads) from ch_trimmed_reads
//     file index from ch_bwa_index.collect()
//
//     output:
//     set val(name), file("*.bam") into ch_bwa_bam
//
//     script:
//     prefix="${name}.Lb"
//     if (!params.seq_center) {
//         rg="\'@RG\\tID:${name}\\tSM:${name.split('_')[0..-2].join('_')}\\tPL:ILLUMINA\\tLB:${name}\\tPU:1\'"
//     } else {
//         rg="\'@RG\\tID:${name}\\tSM:${name.split('_')[0..-2].join('_')}\\tPL:ILLUMINA\\tLB:${name}\\tPU:1\\tCN:${params.seq_center}\'"
//     }
//     """
//     bwa mem \\
//         -t $task.cpus \\
//         -M \\
//         -R $rg \\
//         ${index}/${bwa_base} \\
//         $reads \\
//         | samtools view -@ $task.cpus -b -h -F 0x0100 -O BAM -o ${prefix}.bam -
//     """
// }
//
// /*
//  * STEP 3.2 - Convert .bam to coordinate sorted .bam
//  */
// process sortBAM {
//     tag "$name"
//     label 'process_medium'
//     if (params.saveAlignedIntermediates) {
//         publishDir path: "${params.outdir}/bwa/library", mode: 'copy',
//             saveAs: { filename ->
//                     if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
//                     else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
//                     else if (filename.endsWith(".stats")) "samtools_stats/$filename"
//                     else filename }
//     }
//
//     input:
//     set val(name), file(bam) from ch_bwa_bam
//
//     output:
//     set val(name), file("*.sorted.{bam,bam.bai}") into ch_sort_bam_merge
//     file "*.{flagstat,idxstats,stats}" into ch_sort_bam_flagstat_mqc
//
//     script:
//     prefix="${name}.Lb"
//     """
//     samtools sort -@ $task.cpus -o ${prefix}.sorted.bam -T $name $bam
//     samtools index ${prefix}.sorted.bam
//     samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//     samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//     samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//     """
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                    MERGE LIBRARY BAM                                -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// /*
//  * STEP 4.1 Merge BAM files for all libraries from same sample
//  */
// ch_sort_bam_merge.map { it -> [ it[0].split('_')[0..-2].join('_'), it[1] ] }
//                  .groupTuple(by: [0])
//                  .map { it ->  [ it[0], it[1].flatten() ] }
//                  .set { ch_sort_bam_merge }
//
// process mergeBAM {
//     tag "$name"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary", mode: 'copy',
//         saveAs: { filename ->
//             if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
//             else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
//             else if (filename.endsWith(".stats")) "samtools_stats/$filename"
//             else if (filename.endsWith(".metrics.txt")) "picard_metrics/$filename"
//             else params.saveAlignedIntermediates ? filename : null
//         }
//
//     input:
//     set val(name), file(bams) from ch_sort_bam_merge
//
//     output:
//     set val(name), file("*${prefix}.sorted.{bam,bam.bai}") into ch_merge_bam_filter,
//                                                                 ch_merge_bam_preseq
//     file "*.{flagstat,idxstats,stats}" into ch_merge_bam_stats_mqc
//     file "*.txt" into ch_merge_bam_metrics_mqc
//
//     script:
//     prefix="${name}.mLb.mkD"
//     bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
//     if (!task.memory){
//         log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
//         avail_mem = 3
//     } else {
//         avail_mem = task.memory.toGiga()
//     }
//     if (bam_files.size() > 1) {
//         """
//         picard -Xmx${avail_mem}g MergeSamFiles \\
//             ${'INPUT='+bam_files.join(' INPUT=')} \\
//             OUTPUT=${name}.sorted.bam \\
//             SORT_ORDER=coordinate \\
//             VALIDATION_STRINGENCY=LENIENT \\
//             TMP_DIR=tmp
//         samtools index ${name}.sorted.bam
//
//         picard -Xmx${avail_mem}g MarkDuplicates \\
//             INPUT=${name}.sorted.bam \\
//             OUTPUT=${prefix}.sorted.bam \\
//             ASSUME_SORTED=true \\
//             REMOVE_DUPLICATES=false \\
//             METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
//             VALIDATION_STRINGENCY=LENIENT \\
//             TMP_DIR=tmp
//
//         samtools index ${prefix}.sorted.bam
//         samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//         samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//         samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//         """
//     } else {
//       """
//       picard -Xmx${avail_mem}g MarkDuplicates \\
//           INPUT=${bam_files[0]} \\
//           OUTPUT=${prefix}.sorted.bam \\
//           ASSUME_SORTED=true \\
//           REMOVE_DUPLICATES=false \\
//           METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
//           VALIDATION_STRINGENCY=LENIENT \\
//           TMP_DIR=tmp
//
//       samtools index ${prefix}.sorted.bam
//       samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//       samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//       samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//       """
//     }
// }
//
// /*
//  * STEP 4.2 Filter BAM file at merged library-level
//  */
// process filterBAM {
//     tag "$name"
//     label 'process_medium'
//     publishDir path: "${params.outdir}/bwa/mergedLibrary", mode: 'copy',
//         saveAs: { filename ->
//             if (params.singleEnd || params.saveAlignedIntermediates) {
//                 if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".stats")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".sorted.bam")) filename
//                 else if (filename.endsWith(".sorted.bam.bai")) filename
//                 else null }
//             }
//
//     input:
//     set val(name), file(bam) from ch_merge_bam_filter
//     file bed from ch_genome_filter_regions.collect()
//     file bamtools_filter_config from ch_bamtools_filter_config
//
//     output:
//     set val(name), file("*.{bam,bam.bai}") into ch_filter_bam
//     set val(name), file("*.flagstat") into ch_filter_bam_flagstat
//     file "*.{idxstats,stats}" into ch_filter_bam_stats_mqc
//
//     script:
//     prefix = params.singleEnd ? "${name}.mLb.clN" : "${name}.mLb.flT"
//     filter_params = params.singleEnd ? "-F 0x004" : "-F 0x004 -F 0x0008 -f 0x001"
//     dup_params = params.keepDups ? "" : "-F 0x0400"
//     multimap_params = params.keepMultiMap ? "" : "-q 1"
//     blacklist_params = params.blacklist ? "-L $bed" : ""
//     name_sort_bam = params.singleEnd ? "" : "samtools sort -n -@ $task.cpus -o ${prefix}.bam -T $prefix ${prefix}.sorted.bam"
//     """
//     samtools view \\
//         $filter_params \\
//         $dup_params \\
//         $multimap_params \\
//         $blacklist_params \\
//         -b ${bam[0]} \\
//         | bamtools filter \\
//             -out ${prefix}.sorted.bam \\
//             -script $bamtools_filter_config
//
//     samtools index ${prefix}.sorted.bam
//     samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//     samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//     samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//
//     $name_sort_bam
//     """
// }
//
// /*
//  * STEP 4.3 Remove orphan reads from paired-end BAM file
//  */
// if (params.singleEnd){
//     ch_filter_bam.into { ch_rm_orphan_bam_metrics;
//                          ch_rm_orphan_bam_bigwig;
//                          ch_rm_orphan_bam_macs_1;
//                          ch_rm_orphan_bam_macs_2;
//                          ch_rm_orphan_bam_phantompeakqualtools;
//                          ch_rm_orphan_name_bam_counts }
//     ch_filter_bam_flagstat.into { ch_rm_orphan_flagstat_bigwig;
//                                   ch_rm_orphan_flagstat_macs;
//                                   ch_rm_orphan_flagstat_mqc }
//     ch_filter_bam_stats_mqc.set { ch_rm_orphan_stats_mqc }
// } else {
//     process rmOrphanReads {
//         tag "$name"
//         label 'process_medium'
//         publishDir path: "${params.outdir}/bwa/mergedLibrary", mode: 'copy',
//             saveAs: { filename ->
//                 if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".stats")) "samtools_stats/$filename"
//                 else if (filename.endsWith(".sorted.bam")) filename
//                 else if (filename.endsWith(".sorted.bam.bai")) filename
//                 else null
//             }
//
//         input:
//         set val(name), file(bam) from ch_filter_bam
//
//         output:
//         set val(name), file("*.sorted.{bam,bam.bai}") into ch_rm_orphan_bam_metrics,
//                                                            ch_rm_orphan_bam_bigwig,
//                                                            ch_rm_orphan_bam_macs_1,
//                                                            ch_rm_orphan_bam_macs_2,
//                                                            ch_rm_orphan_bam_phantompeakqualtools
//         set val(name), file("${prefix}.bam") into ch_rm_orphan_name_bam_counts
//         set val(name), file("*.flagstat") into ch_rm_orphan_flagstat_bigwig,
//                                                ch_rm_orphan_flagstat_macs,
//                                                ch_rm_orphan_flagstat_mqc
//         file "*.{idxstats,stats}" into ch_rm_orphan_stats_mqc
//
//         script: // This script is bundled with the pipeline, in nf-core/chipseq/bin/
//         prefix="${name}.mLb.clN"
//         """
//         bampe_rm_orphan.py ${bam[0]} ${prefix}.bam --only_fr_pairs
//
//         samtools sort -@ $task.cpus -o ${prefix}.sorted.bam -T $prefix ${prefix}.bam
//         samtools index ${prefix}.sorted.bam
//         samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
//         samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
//         samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
//         """
//     }
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                 MERGE LIBRARY BAM POST-ANALYSIS                     -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// /*
//  * STEP 5.1 preseq analysis after merging libraries and before filtering
//  */
// process preseq {
//     tag "$name"
//     label 'process_low'
//     publishDir "${params.outdir}/bwa/mergedLibrary/preseq", mode: 'copy'
//
//     when:
//     !params.skipPreseq
//
//     input:
//     set val(name), file(bam) from ch_merge_bam_preseq
//
//     output:
//     file "*.ccurve.txt" into ch_preseq_results
//
//     script:
//     prefix="${name}.mLb.clN"
//     """
//     preseq lc_extrap -v -output ${prefix}.ccurve.txt -bam ${bam[0]}
//     """
// }
//
// /*
//  * STEP 5.2 Picard CollectMultipleMetrics after merging libraries and filtering
//  */
// process collectMultipleMetrics {
//     tag "$name"
//     label 'process_medium'
//     publishDir path: "${params.outdir}/bwa/mergedLibrary", mode: 'copy',
//         saveAs: { filename ->
//             if (filename.endsWith("_metrics")) "picard_metrics/$filename"
//             else if (filename.endsWith(".pdf")) "picard_metrics/pdf/$filename"
//             else null
//         }
//
//     when:
//     !params.skipPicardMetrics
//
//     input:
//     set val(name), file(bam) from ch_rm_orphan_bam_metrics
//     file fasta from ch_fasta
//
//     output:
//     file "*_metrics" into ch_collectmetrics_mqc
//     file "*.pdf" into ch_collectmetrics_pdf
//
//     script:
//     prefix="${name}.mLb.clN"
//     if (!task.memory){
//         log.info "[Picard CollectMultipleMetrics] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
//         avail_mem = 3
//     } else {
//         avail_mem = task.memory.toGiga()
//     }
//     """
//     picard -Xmx${avail_mem}g CollectMultipleMetrics \\
//         INPUT=${bam[0]} \\
//         OUTPUT=${prefix}.CollectMultipleMetrics \\
//         REFERENCE_SEQUENCE=$fasta \\
//         VALIDATION_STRINGENCY=LENIENT \\
//         TMP_DIR=tmp
//     """
// }
//
// /*
//  * STEP 5.3 Read depth normalised bigWig
//  */
// process bigWig {
//     tag "$name"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary/bigwig", mode: 'copy',
//         saveAs: {filename ->
//                     if (filename.endsWith(".txt")) "scale/$filename"
//                     else if (filename.endsWith(".bigWig")) "$filename"
//                     else null
//                 }
//
//     input:
//     set val(name), file(bam), file(flagstat) from ch_rm_orphan_bam_bigwig.join(ch_rm_orphan_flagstat_bigwig, by: [0])
//     file sizes from ch_genome_sizes_bigwig.collect()
//
//     output:
//     set val(name), file("*.bigWig") into ch_bigwig_plotprofile
//     file "*scale_factor.txt" into ch_bigwig_scale
//     file "*igv.txt" into ch_bigwig_igv
//
//     script:
//     prefix="${name}.mLb.clN"
//     pe_fragment = params.singleEnd ? "" : "-pc"
//     extend = (params.singleEnd && params.fragment_size > 0) ? "-fs ${params.fragment_size}" : ''
//     """
//     SCALE_FACTOR=\$(grep 'mapped (' $flagstat | awk '{print 1000000/\$1}')
//     echo \$SCALE_FACTOR > ${prefix}.scale_factor.txt
//     genomeCoverageBed -ibam ${bam[0]} -bg -scale \$SCALE_FACTOR $pe_fragment $extend | sort -k1,1 -k2,2n >  ${prefix}.bedGraph
//
//     bedGraphToBigWig ${prefix}.bedGraph $sizes ${prefix}.bigWig
//
//     find * -type f -name "*.bigWig" -exec echo -e "bwa/mergedLibrary/bigwig/"{}"\\t0,0,178" \\; > ${prefix}.bigWig.igv.txt
//     """
// }
//
// /*
//  * STEP 5.4 generate gene body coverage plot with deepTools
//  */
// process plotProfile {
//     tag "$name"
//     label 'process_high'
//     publishDir "${params.outdir}/bwa/mergedLibrary/deepTools/plotProfile", mode: 'copy'
//
//     when:
//     !params.skipPlotProfile
//
//     input:
//     set val(name), file(bigwig) from ch_bigwig_plotprofile
//     file bed from ch_gene_bed
//
//     output:
//     file '*.{gz,pdf}' into ch_plotprofile_results
//     file '*.plotProfile.tab' into ch_plotprofile_mqc
//
//     script:
//     """
//     computeMatrix scale-regions \\
//         --regionsFileName $bed \\
//         --scoreFileName $bigwig \\
//         --outFileName ${name}.computeMatrix.mat.gz \\
//         --outFileNameMatrix ${name}.computeMatrix.vals.mat.gz \\
//         --regionBodyLength 1000 \\
//         --beforeRegionStartLength 3000 \\
//         --afterRegionStartLength 3000 \\
//         --skipZeros \\
//         --smartLabels \\
//         -p $task.cpus
//
//     plotProfile --matrixFile ${name}.computeMatrix.mat.gz \\
//         --outFileName ${name}.plotProfile.pdf \\
//         --outFileNameData ${name}.plotProfile.tab
//     """
// }
//
// /*
//  * STEP 5.5 Phantompeakqualtools
//  */
// process phantomPeakQualTools {
//     tag "$name"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary/phantompeakqualtools", mode: 'copy'
//
//     when:
//     !params.skipSpp
//
//     input:
//     set val(name), file(bam) from ch_rm_orphan_bam_phantompeakqualtools
//     file spp_correlation_header from ch_spp_correlation_header
//     file spp_nsc_header from ch_spp_nsc_header
//     file spp_rsc_header from ch_spp_rsc_header
//
//     output:
//     file '*.pdf' into ch_spp_plot
//     file '*.spp.out' into ch_spp_out,
//                           ch_spp_out_mqc
//     file '*_mqc.tsv' into ch_spp_csv_mqc
//
//     script:
//     """
//     RUN_SPP=`which run_spp.R`
//     Rscript -e "library(caTools); source(\\"\$RUN_SPP\\")" -c="${bam[0]}" -savp="${name}.spp.pdf" -savd="${name}.spp.Rdata" -out="${name}.spp.out" -p=$task.cpus
//     cp $spp_correlation_header ${name}_spp_correlation_mqc.tsv
//     Rscript -e "load('${name}.spp.Rdata'); write.table(crosscorr\\\$cross.correlation, file=\\"${name}_spp_correlation_mqc.tsv\\", sep=",", quote=FALSE, row.names=FALSE, col.names=FALSE,append=TRUE)"
//
//     awk -v OFS='\t' '{print "${name}", \$9}' ${name}.spp.out | cat $spp_nsc_header - > ${name}_spp_nsc_mqc.tsv
//     awk -v OFS='\t' '{print "${name}", \$10}' ${name}.spp.out | cat $spp_rsc_header - > ${name}_spp_rsc_mqc.tsv
//     """
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                 MERGE LIBRARY PEAK ANALYSIS                         -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// // Create channel linking IP bams with control bams
// ch_rm_orphan_bam_macs_1.combine(ch_rm_orphan_bam_macs_2)
//                        .set { ch_rm_orphan_bam_macs_1 }
// ch_design_controls.combine(ch_rm_orphan_bam_macs_1)
//                       .filter { it[0] == it[5] && it[1] == it[7] }
//                       .join(ch_rm_orphan_flagstat_macs)
//                       .map { it ->  it[2..-1] }
//                       .into { ch_group_bam_macs;
//                               ch_group_bam_plotfingerprint;
//                               ch_group_bam_deseq }
//
// /*
//  * STEP 6.1 deepTools plotFingerprint
//  */
// process plotFingerprint {
//     tag "${ip} vs ${control}"
//     label 'process_high'
//     publishDir "${params.outdir}/bwa/mergedLibrary/deepTools/plotFingerprint", mode: 'copy'
//
//     when:
//     !params.skipPlotFingerprint
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), val(ip), file(ipbam), val(control), file(controlbam), file(ipflagstat) from ch_group_bam_plotfingerprint
//
//     output:
//     file '*.{txt,pdf}' into ch_plotfingerprint_results
//     file '*.raw.txt' into ch_plotfingerprint_mqc
//
//     script:
//     extend = (params.singleEnd && params.fragment_size > 0) ? "--extendReads ${params.fragment_size}" : ''
//     """
//     plotFingerprint \\
//         --bamfiles ${ipbam[0]} ${controlbam[0]} \\
//         --plotFile ${ip}.plotFingerprint.pdf \\
//         $extend \\
//         --labels $ip $control \\
//         --outRawCounts ${ip}.plotFingerprint.raw.txt \\
//         --outQualityMetrics ${ip}.plotFingerprint.qcmetrics.txt \\
//         --skipZeros \\
//         --JSDsample ${controlbam[0]} \\
//         --numberOfProcessors ${task.cpus} \\
//         --numberOfSamples ${params.fingerprint_bins}
//     """
// }
//
// /*
//  * STEP 6.2 Call peaks with MACS2 and calculate FRiP score
//  */
// process macsCallPeak {
//     tag "${ip} vs ${control}"
//     label 'process_long'
//     publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}", mode: 'copy',
//         saveAs: {filename ->
//                     if (filename.endsWith(".tsv")) "qc/$filename"
//                     else if (filename.endsWith(".igv.txt")) null
//                     else filename
//                 }
//
//     when:
//     params.macs_gsize
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), val(ip), file(ipbam), val(control), file(controlbam), file(ipflagstat) from ch_group_bam_macs
//     file peak_count_header from ch_peak_count_header
//     file frip_score_header from ch_frip_score_header
//
//     output:
//     set val(ip), file("*.{bed,xls,gappedPeak,bdg}") into ch_macs_output
//     set val(antibody), val(replicatesExist), val(multipleGroups), val(ip), val(control), file("*.$peaktype") into ch_macs_homer, ch_macs_qc, ch_macs_consensus
//     file "*igv.txt" into ch_macs_igv
//     file "*_mqc.tsv" into ch_macs_mqc
//
//     script:
//     peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//     broad = params.narrowPeak ? '' : "--broad --broad-cutoff ${params.broad_cutoff}"
//     format = params.singleEnd ? "BAM" : "BAMPE"
//     pileup = params.saveMACSPileup ? "-B --SPMR" : ""
//     """
//     macs2 callpeak \\
//         -t ${ipbam[0]} \\
//         -c ${controlbam[0]} \\
//         $broad \\
//         -f $format \\
//         -g ${params.macs_gsize} \\
//         -n $ip \\
//         $pileup \\
//         --keep-dup all \\
//         --nomodel
//
//     cat ${ip}_peaks.${peaktype} | wc -l | awk -v OFS='\t' '{ print "${ip}", \$1 }' | cat $peak_count_header - > ${ip}_peaks.count_mqc.tsv
//
//     READS_IN_PEAKS=\$(intersectBed -a ${ipbam[0]} -b ${ip}_peaks.${peaktype} -bed -c -f 0.20 | awk -F '\t' '{sum += \$NF} END {print sum}')
//     grep 'mapped (' $ipflagstat | awk -v a="\$READS_IN_PEAKS" -v OFS='\t' '{print "${ip}", a/\$1}' | cat $frip_score_header - > ${ip}_peaks.FRiP_mqc.tsv
//
//     find * -type f -name "*.${peaktype}" -exec echo -e "bwa/mergedLibrary/macs/${peaktype}/"{}"\\t0,0,178" \\; > ${ip}_peaks.${peaktype}.igv.txt
//     """
// }
//
// /*
//  * STEP 6.3 Annotate peaks with HOMER
//  */
// process annotatePeaks {
//     tag "${ip} vs ${control}"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}", mode: 'copy'
//
//     when:
//     params.macs_gsize
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), val(ip), val(control), file(peak) from ch_macs_homer
//     file fasta from ch_fasta
//     file gtf from ch_gtf
//
//     output:
//     file "*.txt" into ch_macs_annotate
//
//     script:
//     peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//     """
//     annotatePeaks.pl $peak \\
//         $fasta \\
//         -gid \\
//         -gtf $gtf \\
//         > ${ip}_peaks.annotatePeaks.txt
//     """
// }
//
// /*
//  * STEP 6.4 Aggregated QC plots for peaks, FRiP and peak-to-gene annotation
//  */
// process peakQC {
//    label "process_medium"
//    publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}/qc", mode: 'copy'
//
//    when:
//    params.macs_gsize
//
//    input:
//    file peaks from ch_macs_qc.collect{ it[-1] }
//    file annos from ch_macs_annotate.collect()
//    file peak_annotation_header from ch_peak_annotation_header
//
//    output:
//    file "*.{txt,pdf}" into ch_macs_qc_output
//    file "*.tsv" into ch_macs_qc_mqc
//
//    script:  // This script is bundled with the pipeline, in nf-core/chipseq/bin/
//    peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//    """
//    plot_macs_qc.r -i ${peaks.join(',')} \\
//       -s ${peaks.join(',').replaceAll("_peaks.${peaktype}","")} \\
//       -o ./ \\
//       -p macs_peak
//
//    plot_homer_annotatepeaks.r -i ${annos.join(',')} \\
//       -s ${annos.join(',').replaceAll("_peaks.annotatePeaks.txt","")} \\
//       -o ./ \\
//       -p macs_annotatePeaks
//
//    cat $peak_annotation_header macs_annotatePeaks.summary.txt > macs_annotatePeaks.summary_mqc.tsv
//    """
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                 CONSENSUS PEAKS ANALYSIS                            -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// // group by ip from this point and carry forward boolean variables
// ch_macs_consensus.map { it ->  [ it[0], it[1], it[2], it[-1] ] }
//                  .groupTuple()
//                  .map { it ->  [ it[0], it[1][0], it[2][0], it[3].sort() ] }
//                  .set { ch_macs_consensus }
//
// /*
//  * STEP 7.1 Consensus peaks across samples, create boolean filtering file, .saf file for featureCounts and UpSetR plot for intersection
//  */
// process createConsensusPeakSet {
//     tag "${antibody}"
//     label 'process_long'
//     publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}/consensus/${antibody}", mode: 'copy',
//         saveAs: {filename ->
//                     if (filename.endsWith(".igv.txt")) null
//                     else filename
//                 }
//
//     when:
//     params.macs_gsize && (replicatesExist || multipleGroups)
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), file(peaks) from ch_macs_consensus
//
//     output:
//     set val(antibody), val(replicatesExist), val(multipleGroups), file("*.bed") into ch_macs_consensus_bed
//     set val(antibody), file("*.saf") into ch_macs_consensus_saf
//     file "*.boolean.txt" into ch_macs_consensus_bool
//     file "*.intersect.{txt,plot.pdf}" into ch_macs_consensus_intersect
//     file "*igv.txt" into ch_macs_consensus_igv
//
//     script: // scripts are bundled with the pipeline, in nf-core/chipseq/bin/
//     prefix="${antibody}.consensus_peaks"
//     peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//     mergecols = params.narrowPeak ? (2..10).join(',') : (2..9).join(',')
//     collapsecols = params.narrowPeak ? (["collapse"]*9).join(',') : (["collapse"]*8).join(',')
//     expandparam = params.narrowPeak ? "--is_narrow_peak" : ""
//     """
//     sort -k1,1 -k2,2n ${peaks.collect{it.toString()}.sort().join(' ')} \\
//         | mergeBed -c $mergecols -o $collapsecols > ${prefix}.txt
//
//     macs2_merged_expand.py ${prefix}.txt \\
//         ${peaks.collect{it.toString()}.sort().join(',').replaceAll("_peaks.${peaktype}","")} \\
//         ${prefix}.boolean.txt \\
//         --min_replicates $params.min_reps_consensus \\
//         $expandparam
//
//     awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$1, \$2, \$3, \$4, "0", "+" }' ${prefix}.boolean.txt > ${prefix}.bed
//
//     echo -e "GeneID\tChr\tStart\tEnd\tStrand" > ${prefix}.saf
//     awk -v FS='\t' -v OFS='\t' 'FNR > 1 { print \$4, \$1, \$2, \$3,  "+" }' ${prefix}.boolean.txt >> ${prefix}.saf
//
//     plot_peak_intersect.r -i ${prefix}.boolean.intersect.txt -o ${prefix}.boolean.intersect.plot.pdf
//
//     find * -type f -name "${prefix}.bed" -exec echo -e "bwa/mergedLibrary/macs/${peaktype}/consensus/${antibody}/"{}"\\t0,0,0" \\; > ${prefix}.bed.igv.txt
//     """
// }
//
// /*
//  * STEP 7.2 Annotate consensus peaks with HOMER, and add annotation to boolean output file
//  */
// process annotateConsensusPeakSet {
//     tag "${antibody}"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}/consensus/${antibody}", mode: 'copy'
//
//     when:
//     params.macs_gsize && (replicatesExist || multipleGroups)
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), file(bed) from ch_macs_consensus_bed
//     file bool from ch_macs_consensus_bool
//     file fasta from ch_fasta
//     file gtf from ch_gtf
//
//     output:
//     file "*.annotatePeaks.txt" into ch_macs_consensus_annotate
//
//     script:
//     prefix="${antibody}.consensus_peaks"
//     peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//     """
//     annotatePeaks.pl $bed \\
//         $fasta \\
//         -gid \\
//         -gtf $gtf \\
//         > ${prefix}.annotatePeaks.txt
//
//     cut -f2- ${prefix}.annotatePeaks.txt | awk 'NR==1; NR > 1 {print \$0 | "sort -k1,1 -k2,2n"}' | cut -f6- > tmp.txt
//     paste $bool tmp.txt > ${prefix}.boolean.annotatePeaks.txt
//     """
// }
//
// // get bam and saf files for each ip
// ch_group_bam_deseq.map { it -> [ it[3], [ it[0], it[1], it[2] ] ] }
//                   .join(ch_rm_orphan_name_bam_counts)
//                   .map { it -> [ it[1][0], it[1][1], it[1][2], it[2] ] }
//                   .groupTuple()
//                   .map { it -> [ it[0], it[1][0], it[2][0], it[3].flatten().sort() ] }
//                   .join(ch_macs_consensus_saf)
//                   .set { ch_group_bam_deseq }
//
// /*
//  * STEP 7.3 Count reads in consensus peaks with featureCounts and perform differential analysis with DESeq2
//  */
// process deseqConsensusPeakSet {
//     tag "${antibody}"
//     label 'process_medium'
//     publishDir "${params.outdir}/bwa/mergedLibrary/macs/${peaktype}/consensus/${antibody}/deseq2", mode: 'copy',
//         saveAs: {filename ->
//                     if (filename.endsWith(".igv.txt")) null
//                     else filename
//                 }
//
//     when:
//     params.macs_gsize && !params.skipDiffAnalysis && replicatesExist && multipleGroups
//
//     input:
//     set val(antibody), val(replicatesExist), val(multipleGroups), file(bams) ,file(saf) from ch_group_bam_deseq
//     file deseq2_pca_header from ch_deseq2_pca_header
//     file deseq2_clustering_header from ch_deseq2_clustering_header
//
//     output:
//     file "*featureCounts.txt" into ch_macs_consensus_counts
//     file "*featureCounts.txt.summary" into ch_macs_consensus_counts_mqc
//     file "*.{RData,results.txt,pdf,log}" into ch_macs_consensus_deseq_results
//     file "sizeFactors" into ch_macs_consensus_deseq_factors
//     file "*vs*/*.{pdf,txt}" into ch_macs_consensus_deseq_comp_results
//     file "*vs*/*.bed" into ch_macs_consensus_deseq_comp_bed
//     file "*igv.txt" into ch_macs_consensus_deseq_comp_igv
//     file "*.tsv" into ch_macs_consensus_deseq_mqc
//
//     script:
//     prefix="${antibody}.consensus_peaks"
//     peaktype = params.narrowPeak ? "narrowPeak" : "broadPeak"
//     bam_files = bams.findAll { it.toString().endsWith('.bam') }.sort()
//     bam_ext = params.singleEnd ? ".mLb.clN.sorted.bam" : ".mLb.clN.bam"
//     pe_params = params.singleEnd ? '' : "-p --donotsort"
//     """
//     featureCounts -F SAF \\
//         -O \\
//         --fracOverlap 0.2 \\
//         -T $task.cpus \\
//         $pe_params \\
//         -a $saf \\
//         -o ${prefix}.featureCounts.txt \\
//         ${bam_files.join(' ')}
//
//     featurecounts_deseq2.r -i ${prefix}.featureCounts.txt -b '$bam_ext' -o ./ -p $prefix -s .mLb
//
//     sed 's/deseq2_pca/deseq2_pca_${task.index}/g' <$deseq2_pca_header >tmp.txt
//     sed -i -e 's/DESeq2:/${antibody} DESeq2:/g' tmp.txt
//     cat tmp.txt ${prefix}.pca.vals.txt > ${prefix}.pca.vals_mqc.tsv
//
//     sed 's/deseq2_clustering/deseq2_clustering_${task.index}/g' <$deseq2_clustering_header >tmp.txt
//     sed -i -e 's/DESeq2:/${antibody} DESeq2:/g' tmp.txt
//     cat tmp.txt ${prefix}.sample.dists.txt > ${prefix}.sample.dists_mqc.tsv
//
//     find * -type f -name "*.FDR0.05.results.bed" -exec echo -e "bwa/mergedLibrary/macs/${peaktype}/consensus/${antibody}/deseq2/"{}"\\t255,0,0" \\; > ${prefix}.igv.txt
//     """
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                             IGV                                     -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// /*
//  * STEP 8 - Create IGV session file
//  */
// process igv {
//     publishDir "${params.outdir}/igv", mode: 'copy'
//
//     when:
//     !params.skipIGV
//
//     input:
//     file fasta from ch_fasta
//     file bigwigs from ch_bigwig_igv.collect().ifEmpty([])
//     file peaks from ch_macs_igv.collect().ifEmpty([])
//     file consensus_peaks from ch_macs_consensus_igv.collect().ifEmpty([])
//     file differential_peaks from ch_macs_consensus_deseq_comp_igv.collect().ifEmpty([])
//
//     output:
//     file "*.{txt,xml}" into ch_igv_session
//
//     script: // scripts are bundled with the pipeline, in nf-core/chipseq/bin/
//     """
//     cat *.txt > igv_files.txt
//     igv_files_to_session.py igv_session.xml igv_files.txt ../reference_genome/${fasta.getName()} --path_prefix '../'
//     """
// }
//
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
// /* --                                                                     -- */
// /* --                          MULTIQC                                    -- */
// /* --                                                                     -- */
// ///////////////////////////////////////////////////////////////////////////////
// ///////////////////////////////////////////////////////////////////////////////
//
// /*
//  * STEP 9 - MultiQC
//  */
// process multiqc {
//     publishDir "${params.outdir}/multiqc", mode: 'copy'
//
//     when:
//     !params.skipMultiQC
//
//     input:
//     file multiqc_config from ch_multiqc_config
//
//     file ('fastqc/*') from ch_fastqc_reports_mqc.collect()
//     file ('trimgalore/*') from ch_trimgalore_results_mqc.collect()
//     file ('trimgalore/fastqc/*') from ch_trimgalore_fastqc_reports_mqc.collect()
//
//     file ('alignment/library/*') from ch_sort_bam_flagstat_mqc.collect()
//     file ('alignment/mergedLibrary/*') from ch_merge_bam_stats_mqc.collect()
//     file ('alignment/mergedLibrary/*') from ch_rm_orphan_flagstat_mqc.collect{it[1]}
//     file ('alignment/mergedLibrary/*') from ch_rm_orphan_stats_mqc.collect()
//     file ('alignment/mergedLibrary/picard_metrics/*') from ch_merge_bam_metrics_mqc.collect()
//     file ('alignment/mergedLibrary/picard_metrics/*') from ch_collectmetrics_mqc.collect()
//
//     file ('macs/*') from ch_macs_mqc.collect().ifEmpty([])
//     file ('macs/*') from ch_macs_qc_mqc.collect().ifEmpty([])
//     file ('macs/consensus/*') from ch_macs_consensus_counts_mqc.collect().ifEmpty([])
//     file ('macs/consensus/*') from ch_macs_consensus_deseq_mqc.collect().ifEmpty([])
//
//     file ('preseq/*') from ch_preseq_results.collect().ifEmpty([])
//     file ('deeptools/*') from ch_plotfingerprint_mqc.collect().ifEmpty([])
//     file ('deeptools/*') from ch_plotprofile_mqc.collect().ifEmpty([])
//     file ('phantompeakqualtools/*') from ch_spp_out_mqc.collect().ifEmpty([])
//     file ('phantompeakqualtools/*') from ch_spp_csv_mqc.collect().ifEmpty([])
//     file ('software_versions/*') from ch_software_versions_mqc.collect()
//     file ('workflow_summary/*') from create_workflow_summary(summary)
//
//     output:
//     file "*multiqc_report.html" into ch_multiqc_report
//     file "*_data"
//     file "multiqc_plots"
//
//     script:
//     rtitle = params.run_name ? "--title \"$params.run_name\"" : ''
//     rfilename = params.run_name ? "--filename " + params.run_name.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
//     mqcstats = params.skipMultiQCStats ? '--cl_config "skip_generalstats: true"' : ''
//     """
//     multiqc . -f $rtitle $rfilename --config $multiqc_config \\
//         -m custom_content -m fastqc -m cutadapt -m samtools -m picard -m preseq -m featureCounts -m deeptools -m phantompeakqualtools \\
//         $mqcstats
//     """
// }
