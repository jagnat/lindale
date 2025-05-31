// References:
//
//    How to implement fast convolution and fast correlation in the frequency domain,
//    with FFT's.
//
//    See 
//       How do I implement cross-correlation to prove two audio files are similar?
//       https://dsp.stackexchange.com/questions/736/how-do-i-implement-cross-correlation-to-prove-two-audio-files-are-similar
//

package ufft_dif   // Decimation in frequency radix-2

import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:c/libc"
import "core:mem"
import "core:os"


// This is the common preparation phase between the convolution and the cross-correlation.
@(private="file")
pre_common_part :: proc ( vector_a : [ ^ ]complex64, N_a : int, vector_b : [ ^ ]complex64, N_b : int ) ->
                        ( vec_a_pad  : [ ^ ]complex64,
                          vec_b_pad  : [ ^ ]complex64,
                          vector_res : [ ^ ]complex64,
                          N_c : int )   {

        // Check if the vector_a is not nil.
        if vector_a == nil {
            fmt.printf( "Error : The vector_a is nil!\n" )
            os.exit( 1 )
        }
    
        // Check if the vectors_b is not nil.
        if vector_a == nil {
            fmt.printf( "Error : The vector_b is nil!\n" )
            os.exit( 1 )
        }
    
        // Chect if the N_a size of the vector_a is greater or equal to 1.
        if N_a <= 0 {
            fmt.printf( "Error : The N_a size of the vector_a is invalid!\n" )
            os.exit( 1 )
        }
        
        // Chect if the N_b size of the vector_b is greater or equal to 1.
        if N_b <= 0 {
            fmt.printf( "Error : The N_b size of the vector_b is invalid!\n" )
            os.exit( 1 )
        }
    
        // Determine the size of the FFT input vectors and the result vector.
        // N = size( a ) + size( b ) - 1
        N_c_start : int = N_a + N_b - 1
    
        // Find the next power of 2 of the result vector.
        N_c = 1 << uint( 1 + int( math.log2( f64( N_c_start ) ) ) )
    
        // fmt.printf( "remove_circular N_c_start = %d,  next power of two -> N_c = %d\n\n", N_c_start, N_c )
    
        // The followin code already zeros the vectors.
        // Odin always zero the memory when we allocate it.
    
        // Allocate the result vec_a_padded.
        vec_a_pad = make( [ ^ ]complex64, N_c )
        if vec_a_pad == nil {
            fmt.printf( "Error : Failed to allocate the vector_a_padded!\n" )
            os.exit( 1 )
        }
    
        // Allocate the result vec_b_padded.
        vec_b_pad = make( [ ^ ]complex64, N_c )
        if vec_b_pad == nil {
            fmt.printf( "Error : Failed to allocate the vector_b_padded!\n" )
            os.exit( 1 )
        }
    
        // Allocate the result vector.
        vector_res = make( [ ^ ]complex64, N_c )
        if vector_res == nil {
            fmt.printf( "Error : Failed to allocate the result vector!\n" )
            os.exit( 1 )
        }
    
        // Fill in the vec_a_padded with the vector_a.
        libc.memmove( vec_a_pad, vector_a, uint( N_a * size_of( complex64 ) ) )
        
        // Fill in the vec_b_padded with the vector_b.
        libc.memmove( vec_b_pad, vector_b, uint( N_b * size_of( complex64 ) ) )
    
        return vec_a_pad, vec_b_pad, vector_res, N_c
} 

// This is a 1D vector convolution between vector_a and vector_b.
// Convolution done with the FFT in the frequency is faster than the direct convolution in the time domain.
// If we do the convolution with the same size has de maximum size of the greatest vector of the two,
// we will have as result a circular convolution. To avoid this, we need to zero pad the vectors to
// N_res = size( a ) + size( b ) - 1 and then to speed up the computation to use the to the next power of 2.
// Note : Our lib uFFT only works with power of 2 sizes.
// Vectors are complex64, that is 2x f32, real part and imaginary part.
//
// conv( a, b ) = ifft( fft( a_and_zeros ) * fft( b_and_zeros ) )
//
convolution :: proc ( vector_a : [ ^ ]complex64, N_a : int, vector_b : [ ^ ]complex64, N_b : int ) ->
                    ( vector_res : [ ^ ]complex64, N_c : int )   {

    vec_a_pad : [ ^ ]complex64
    vec_b_pad : [ ^ ]complex64
    // Call the common preparation phase.
    vec_a_pad, vec_b_pad, vector_res, N_c = pre_common_part( vector_a, N_a,
                                                             vector_b, N_b )

    // Call the FFT for the vec_a_padded.
    fft( vec_a_pad, N_c )

    // Call the FFT for the vec_b_padded.
    fft( vec_b_pad, N_c )

    // Complex Multiply the vec_a_padded and vec_b_padded into vector_res.
    for i in 0 ..< N_c {
        vector_res[ i ] = vec_a_pad[ i ] * vec_b_pad[ i ]
    }

    // Call the inverse FFT for the vector_res.
    ift( vector_res, N_c )

    return vector_res, N_c
} 


// This is a 1D vector cross_correlation between vector_a and vector_b.
// Correlation done with the FFT in the frequency is faster than the direct correlation in the time domain.
// If we do the correlation with the same size has de maximum size of the greatest vector of the two, we
// will have as result a circular correlation. To avoid this, we need to zero pad the vectors to
// N_res = size( a ) + size( b ) - 1 and then to speed up the computation to use the to the next power of 2.
// Note : Our lib uFFT only works with power of 2 sizes.
// Vectors are complex64, that is 2x f32, real part and imaginary part.
//
// cross_correlation( a, b ) = ifft( fft( a_and_zeros ) * complex_conj( fft( b_and_zeros ) ) )
//
cross_correlation :: proc ( vector_a : [ ^ ]complex64, N_a : int, vector_b : [ ^ ]complex64, N_b : int ) ->
                          ( vector_res : [ ^ ]complex64, N_c : int )   {

    vec_a_pad : [ ^ ]complex64
    vec_b_pad : [ ^ ]complex64
                        
    // Call the common preparation phase.
    vec_a_pad, vec_b_pad, vector_res, N_c = pre_common_part( vector_a, N_a,
                                                             vector_b, N_b )

    // Call the FFT for the vec_a_padded.
    fft( vec_a_pad, N_c )

    // Call the FFT for the vec_b_padded.
    fft( vec_b_pad, N_c )

    // Complex Multiply the vec_a_padded and vec_b_padded into vector_res.
    for i in 0 ..<N_c {
        vector_res[ i ] = vec_a_pad[ i ] * cmplx.conj( vec_b_pad[ i ] )
    }

    // Call the inverse FFT for the vector_res.
    ift( vector_res, N_c )

    return vector_res, N_c
}

// This is a 1D vector auto_correlation of the vector_a with him self.
// auto_correlation done with the FFT in the frequency is faster than the direct auto_correlation in the time domain.
// If we do the auto_correlation with the same size has the vector, we will have as result a circular auto_correlation.
// To avoid this, we need to zero pad the vectors to N_res = size( a ) + size( a ) - 1 and then to speed up the
// computation to use the to the next power of 2.
// Note : Our lib uFFT only works with power of 2 sizes.
// Vector must be are complex64, that is 2x f32, real part and imaginary part.
//
// auto_correlation( a, b ) = ifft( fft( a_and_zeros ) * complex_conj( fft( a_and_zeros ) ) )
//
auto_correlation :: proc ( vector_a : [ ^ ]complex64, N_a : int ) ->
                         ( vector_res : [ ^ ]complex64, N_c : int )   {

    // To make the auto_correlation we need to call the cross_correlation with the same vector.
    vector_res, N_c = cross_correlation( vector_a, N_a, vector_a, N_a )

    return vector_res, N_c
}
